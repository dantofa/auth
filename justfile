# Cluster-ops recipes (`just cluster ...`) from the dantofa platform devbox plugin.
import '.just/cluster.just'

# Platform layers the auth reconcile root waits for: the ingress controller, the
# Bitwarden ClusterSecretStore, and the CNPG backup-destination generator.
auth_depends_on := "ingress,eso-config,cnpg-backup-destination"

# Registers this repo's `auth` OCI source next to the platform's (same in-cluster
# registry), publishes ./flux to it, and layers the flux/auth reconcile root on top.
# Deploy Zitadel to the local kind cluster
deploy-local:
  #!/usr/bin/env bash
  set -euo pipefail
  export KUBECONFIG="${KUBECONFIG:-.kubeconfig}"
  # shellcheck disable=SC2206
  dctl=(${DCTL:-nix run github:dantofa/platform#default --})
  platform_url=$(kubectl -n flux-system get ocirepository platform -o jsonpath='{.spec.url}')
  "${dctl[@]}" flux source create auth --type oci --insecure --url "${platform_url%/*}/auth"
  "${dctl[@]}" local cluster push --name auth
  "${dctl[@]}" flux kustomization create auth --type oci --source auth \
    --path ./flux/auth --substitute --depends-on {{auth_depends_on}}

deploy-doks:
  #!/usr/bin/env bash
  set -euo pipefail
  : "${GITHUB_SERVER_URL:=https://github.com}"
  : "${GITHUB_REPOSITORY:=$(git remote get-url origin | sed -E 's#^.*github\.com[:/]##; s#\.git$##')}"
  : "${GITHUB_REF_NAME:=$(git branch --show-current)}"
  # shellcheck disable=SC2206
  dctl=(${DCTL:-nix run github:dantofa/platform#default --})
  "${dctl[@]}" flux source create auth --type git \
    --url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY" --revision "$GITHUB_REF_NAME" \
    ${DCTL_SOURCE_TOKEN:+--token "$DCTL_SOURCE_TOKEN"}
  "${dctl[@]}" flux kustomization create auth --type git --source auth \
    --path ./flux/auth --substitute --depends-on {{auth_depends_on}}

# Locally, export the CA first (`just cluster local ca`) or pass CURL_FLAGS=-k.
# Gate on the auth root reconciling and Zitadel serving OIDC discovery
verify:
  #!/usr/bin/env bash
  set -euo pipefail
  export KUBECONFIG="${KUBECONFIG:-.kubeconfig}"
  base_domain="${BASE_DOMAIN:-local.dantofa.dev}"
  kubectl -n flux-system wait kustomization/auth --for=condition=Ready --timeout="${FLUX_TIMEOUT:-900s}"
  # shellcheck disable=SC2086
  curl -fsS ${CURL_FLAGS:-} "https://auth.${base_domain}/.well-known/openid-configuration" \
    | jq -e --arg iss "https://auth.${base_domain}" '.issuer == $iss'
