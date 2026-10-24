# Cluster-ops recipes (`just cluster ...`) from the dantofa platform devbox plugin.
import '.just/cluster.just'

# A pull-request deploy (`pr` = the PR number) is served at auth<N>.${base_domain}
# instead of auth.${base_domain}. Each PR has its own cluster, so everything inside
# it is still plain `auth`; only the hostname has to differ, because every preview
# cluster publishes DNS into the same zone under the same base_domain. In GitHub
# Actions pass `${{ github.event.number }}`. Tear a PR down with
# `just cluster doks delete`, which drains the cluster's DNS records first.

# Apply the flux/auth reconcile root. Written here rather than with
# `dctl flux kustomization create`, which cannot set the auth_host substitution;
# otherwise the same shape (wait, cluster-vars substitution, ordered after the
# platform layers it needs: the ingress controller, the Bitwarden
# ClusterSecretStore, and the CNPG backup-destination generator).
_reconcile-root source_kind host:
  #!/usr/bin/env bash
  set -euo pipefail
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
    postBuild:
      substitute:
        auth_host: {{host}}
      substituteFrom:
        - kind: ConfigMap
          name: cluster-vars
  EOF

# Registers this repo's `auth` OCI source next to the platform's (same in-cluster
# registry), publishes ./flux to it, and layers the flux/auth reconcile root on top.
# Deploy Zitadel to the local kind cluster at auth.${BASE_DOMAIN}
deploy-local:
  #!/usr/bin/env bash
  set -euo pipefail
  export KUBECONFIG="${KUBECONFIG:-.kubeconfig}"
  # shellcheck disable=SC2206
  dctl=(${DCTL:-nix run github:dantofa/platform#default --})
  platform_url=$(kubectl -n flux-system get ocirepository platform -o jsonpath='{.spec.url}')
  "${dctl[@]}" flux source create auth --type oci --insecure --url "${platform_url%/*}/auth"
  "${dctl[@]}" local cluster push --name auth
  just _reconcile-root OCIRepository auth

# The source is named by the GitHub Actions variables, defaulting locally to the
# `origin` repo and the checked-out branch (push it first). On pull_request events
# the PR's head branch ($GITHUB_HEAD_REF) is tracked, not the merge ref.
# Deploy Zitadel to the DOKS cluster in $KUBECONFIG (pass a PR number for auth<N>)
deploy-doks pr="":
  #!/usr/bin/env bash
  set -euo pipefail
  pr="{{pr}}"
  [[ "$pr" =~ ^[0-9]*$ ]] || { echo "deploy-doks: pr must be a number, got '$pr'" >&2; exit 1; }
  : "${GITHUB_SERVER_URL:=https://github.com}"
  : "${GITHUB_REPOSITORY:=$(git remote get-url origin | sed -E 's#^.*github\.com[:/]##; s#\.git$##')}"
  : "${GITHUB_REF_NAME:=$(git branch --show-current)}"
  # shellcheck disable=SC2206
  dctl=(${DCTL:-nix run github:dantofa/platform#default --})
  "${dctl[@]}" flux source create auth --type git \
    --url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY" --revision "${GITHUB_HEAD_REF:-$GITHUB_REF_NAME}" \
    ${DCTL_SOURCE_TOKEN:+--token "$DCTL_SOURCE_TOKEN"}
  just _reconcile-root GitRepository "auth$pr"

# Deployment gate, the same locally and in CI:
#   1. Flux applied the expected commit ($EXPECTED_SHA, when set) and is healthy
#   2. the database is up, archiving WAL, and has a completed base backup
#   3. Zitadel answers at the public URL: ready, OIDC issuer, login UI
# Curl retries cover a fresh hostname whose DNS record the tunnel just created.
# Locally, export the CA first (`just cluster local ca`) or pass CURL_FLAGS=-k.
# Gate on the auth deployment: Flux revision, database backups, public endpoints
verify pr="":
  #!/usr/bin/env bash
  set -euo pipefail
  export KUBECONFIG="${KUBECONFIG:-.kubeconfig}"
  base_domain="${BASE_DOMAIN:-local.dantofa.dev}"
  issuer="https://auth{{pr}}.${base_domain}"
  timeout="${FLUX_TIMEOUT:-20m}"
  step() { echo "--- $*"; }

  step "Flux: reconcile the auth root from its source"
  flux reconcile kustomization auth --with-source --timeout "$timeout"
  kubectl -n flux-system wait kustomization/auth --for=condition=Ready --timeout="$timeout"
  applied=$(kubectl -n flux-system get kustomization auth -o jsonpath='{.status.lastAppliedRevision}')
  echo "applied revision: $applied"
  if [[ -n "${EXPECTED_SHA:-}" && "$applied" != *"$EXPECTED_SHA" ]]; then
    echo "verify: expected commit $EXPECTED_SHA, Flux applied $applied" >&2
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

  # shellcheck disable=SC2206
  curl=(curl -fsS --retry 30 --retry-delay 10 --retry-all-errors ${CURL_FLAGS:-})
  step "Zitadel: $issuer"
  "${curl[@]}" -o /dev/null "$issuer/debug/ready"
  "${curl[@]}" "$issuer/.well-known/openid-configuration" \
    | jq -e --arg iss "$issuer" '.issuer == $iss' >/dev/null
  "${curl[@]}" -L -o /dev/null "$issuer/ui/v2/login/"
  echo "verify: auth{{pr}} OK"
