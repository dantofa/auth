# Cluster-ops recipes (`just cluster ...`) from the dantofa platform devbox plugin.
import '.just/cluster.just'

# Zitadel is served at auth.${base_domain}. A PR preview (.github/workflows/preview.yaml)
# gets its own cluster and base domain, so nothing here is PR-specific.

# Apply the flux/auth reconcile root. Written here rather than with
# `dctl flux kustomization create`, which cannot set substitutions; otherwise the
# same shape (wait, cluster-vars substitution, ordered after the
# platform layers it needs: the ingress controller, the Bitwarden
# ClusterSecretStore, and the CNPG backup-destination generator).
# $AUTH_INSTANCE and $AUTH_ORG, when set, override the instance and first org's
# names (the manifests default both to dantofa), and $AUTH_ADMIN_DOMAIN the domain
# of the first admin's login name (default dantofa.dev); they only take effect on a
# fresh install.
_reconcile-root source_kind:
  #!/usr/bin/env bash
  set -euo pipefail
  # Flux substitutes into re-serialized YAML, where the names land as plain
  # scalars, so they are limited to characters that stay a valid plain string.
  extra=""
  for var in AUTH_INSTANCE AUTH_ORG; do
    value=${!var:-}
    [[ -n "$value" ]] || continue
    if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]*$ ]]; then
      echo "_reconcile-root: $var may only contain letters, digits, spaces, . _ - (got '$value')" >&2
      exit 1
    fi
    extra+=$'\n'"      ${var,,}: \"$value\""
  done
  if [[ -n "${AUTH_ADMIN_DOMAIN:-}" ]]; then
    if [[ ! "$AUTH_ADMIN_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
      echo "_reconcile-root: AUTH_ADMIN_DOMAIN must be a lowercase domain name (got '$AUTH_ADMIN_DOMAIN')" >&2
      exit 1
    fi
    extra+=$'\n'"      auth_admin_domain: \"$AUTH_ADMIN_DOMAIN\""
  fi
  [[ -z "$extra" ]] || extra=$'\n'"    substitute:${extra}"
  kubectl apply -f - <<EOF
  apiVersion: kustomize.toolkit.fluxcd.io/v1
  kind: Kustomization
  metadata:
    name: auth
    namespace: flux-system
  spec:
    interval: 10m
    retryInterval: 1m
    # Above the HelmRelease's 15m: a cold install waits on CNPG and the init jobs.
    timeout: 20m
    path: ./flux/auth
    prune: true
    wait: true
    dependsOn:
      - name: ingress
      - name: eso-config
      - name: cnpg-backup-destination
    sourceRef:
      kind: {{source_kind}}
      name: auth
    postBuild:${extra}
      substituteFrom:
        - kind: ConfigMap
          name: cluster-vars
  EOF

deploy arg:
  just --justfile {{justfile()}} deploy-{{arg}}

# Publishes this repo to the in-cluster registry as the `auth` artifact (push also
# registers the matching OCIRepository) and layers the flux/auth reconcile root on top.
# Deploy Zitadel to the local kind cluster at auth.${BASE_DOMAIN}
deploy-local:
  #!/usr/bin/env bash
  set -euo pipefail
  export KUBECONFIG="${KUBECONFIG:-.kubeconfig}"
  # shellcheck disable=SC2206
  dctl=(${DCTL:-nix run github:dantofa/platform#default --})
  "${dctl[@]}" local cluster push --name auth
  just _reconcile-root OCIRepository
  just zitadel-credentials

zitadel arg:
  just --justfile {{justfile()}} zitadel-{{arg}}

# The login is read from the deployed HelmRelease (ExternalDomain, the first org
# and admin user), so it reflects what was installed rather than this checkout's
# defaults. A username with its own @domain is the login name as-is; Zitadel only
# suffixes one without, with the org domain: the org name with spaces as hyphens,
# characters other than letters, digits and hyphens dropped, lowercased, under
# ExternalDomain.
# The password is the initial one from the zitadel-admin Secret: Zitadel forces a
# change on first login and never writes the new one back. Waits (up to 5m) only
# for those two objects, not for Zitadel to be ready; `just verify` does that.
# Print the Zitadel console URL and the initial admin login
zitadel-credentials:
  #!/usr/bin/env bash
  set -euo pipefail
  export KUBECONFIG="${KUBECONFIG:-.kubeconfig}"
  for _ in $(seq 1 60); do
    kubectl -n auth get helmrelease/zitadel secret/zitadel-admin >/dev/null 2>&1 && break
    sleep 5
  done
  config=$(kubectl -n auth get helmrelease zitadel -o json | jq -c '.spec.values.zitadel.configmapConfig')
  host=$(jq -r '.ExternalDomain' <<<"$config")
  org=$(jq -r '.FirstInstance.Org.Name' <<<"$config")
  user=$(jq -r '.FirstInstance.Org.Human.UserName' <<<"$config")
  if [[ "$user" != *@* ]]; then
    label=${org// /-}
    label=${label//[^A-Za-z0-9-]/}
    user+="@${label,,}.${host}"
  fi
  password=$(kubectl -n auth get secret zitadel-admin -o jsonpath='{.data.password}' | base64 -d)
  echo "Console:  https://${host}/ui/console"
  echo "Login:    ${user}"
  echo "Password: ${password}  (initial; changed on first login)"

# With no --url, dctl points the source at this repository: under GitHub Actions the
# PR's head branch (not the merge ref), locally `origin` and the checked-out branch
# (push it first).
# Deploy Zitadel to the DOKS cluster in $KUBECONFIG
deploy-doks:
  #!/usr/bin/env bash
  set -euo pipefail
  # shellcheck disable=SC2206
  dctl=(${DCTL:-nix run github:dantofa/platform#default --})
  "${dctl[@]}" flux source create auth --type git
  just _reconcile-root GitRepository

# Deployment gate, the same locally and in CI:
#   1. Flux applied the expected commit ($EXPECTED_SHA, else the preview workflow's
#      $PR_HEAD_SHA, when set) and is healthy
#   2. the database is up, archiving WAL, and has a completed base backup
#   3. Zitadel answers at the public URL: ready, OIDC issuer, login UI
# The URL is read from the deployed Ingress rather than rebuilt here, so the gate
# tests the hostname the manifests produced, and the issuer check catches an
# Ingress host that disagrees with Zitadel's ExternalDomain.
# Curl retries cover a fresh hostname whose DNS record the tunnel just created.
# Locally, export the CA first (`just cluster local ca`) or pass CURL_FLAGS=-k.
# Gate on the auth deployment: Flux revision, database backups, public endpoints
verify:
  #!/usr/bin/env bash
  set -euo pipefail
  export KUBECONFIG="${KUBECONFIG:-.kubeconfig}"
  timeout="${FLUX_TIMEOUT:-20m}"
  step() { echo "--- $*"; }

  step "Flux: reconcile the auth root from its source"
  flux reconcile kustomization auth --with-source --timeout "$timeout"
  kubectl -n flux-system wait kustomization/auth --for=condition=Ready --timeout="$timeout"
  expected="${EXPECTED_SHA:-${PR_HEAD_SHA:-}}"
  applied=$(kubectl -n flux-system get kustomization auth -o jsonpath='{.status.lastAppliedRevision}')
  echo "applied revision: $applied"
  if [[ -n "$expected" && "$applied" != *"$expected" ]]; then
    echo "verify: expected commit $expected, Flux applied $applied" >&2
    exit 1
  fi

  step "Database: ready, archiving WAL, base backup completed"
  kubectl -n auth wait cluster.postgresql.cnpg.io/zitadel-db --for=condition=Ready --timeout="$timeout"
  kubectl -n auth wait cluster.postgresql.cnpg.io/zitadel-db --for=condition=ContinuousArchiving --timeout=10m
  for _ in $(seq 1 60); do
    phase=$(kubectl -n auth get backup -l cnpg.io/scheduled-backup=zitadel-db-daily \
      -o jsonpath='{.items[*].status.phase}')
    [[ " $phase " == *" completed "* ]] && break
    [[ " $phase " == *" failed "* ]] && { kubectl -n auth describe backup; exit 1; }
    sleep 10
  done
  [[ " $phase " == *" completed "* ]] || { echo "verify: no completed base backup (phases: ${phase:-none})" >&2; exit 1; }

  host=$(kubectl -n auth get ingress zitadel -o jsonpath='{.spec.rules[0].host}')
  [[ -n "$host" ]] || { echo "verify: ingress auth/zitadel has no host" >&2; exit 1; }
  issuer="https://${host}"
  # shellcheck disable=SC2206
  curl=(curl -fsS --retry 30 --retry-delay 10 --retry-all-errors ${CURL_FLAGS:-})
  step "Zitadel: $issuer"
  "${curl[@]}" -o /dev/null "$issuer/debug/ready"
  "${curl[@]}" "$issuer/.well-known/openid-configuration" \
    | jq -e --arg iss "$issuer" '.issuer == $iss' >/dev/null
  "${curl[@]}" -L -o /dev/null "$issuer/ui/v2/login/"
  echo "verify: $host OK"
