#!/usr/bin/env bash

set -euo pipefail

VERBOSE="${VERBOSE:-0}"
if [[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]]; then
  VERBOSE=1
  shift
fi

if [[ "${VERBOSE}" == "1" ]]; then
  PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
  set -x
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export HELM_CONFIG_HOME="${ROOT_DIR}/.helm/config"
export HELM_CACHE_HOME="${ROOT_DIR}/.helm/cache"
export HELM_DATA_HOME="${ROOT_DIR}/.helm/data"

CHART_REPO="hashicorp"
CHART_NAME="vault"
CHART_VERSION="0.32.0"
KIND_CONTEXT="kind-vault-lab"

mkdir -p "${HELM_CONFIG_HOME}" "${HELM_CACHE_HOME}" "${HELM_DATA_HOME}"

CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
if [[ "${CURRENT_CONTEXT}" != "${KIND_CONTEXT}" ]]; then
  echo "Current kubectl context is '${CURRENT_CONTEXT:-<none>}'." >&2
  echo "Switch to '${KIND_CONTEXT}' first, or create it with ./scripts/create-kind-cluster.sh." >&2
  exit 1
fi

kubectl apply -f "${ROOT_DIR}/namespaces.yaml"

helm repo add "${CHART_REPO}" https://helm.releases.hashicorp.com || true
helm repo update

helm upgrade --install vault-a "${CHART_REPO}/${CHART_NAME}" \
  --namespace vault-a \
  --version "${CHART_VERSION}" \
  --values "${ROOT_DIR}/values/vault-cluster-a.yaml" \
  --wait \
  --timeout 15m

helm upgrade --install vault-b "${CHART_REPO}/${CHART_NAME}" \
  --namespace vault-b \
  --version "${CHART_VERSION}" \
  --values "${ROOT_DIR}/values/vault-cluster-b.yaml" \
  --wait \
  --timeout 15m

cat <<'EOF'
Vault clusters deployed.

Cluster A UI/API: http://127.0.0.1:32080
Cluster B UI/API: http://127.0.0.1:32081

Next, initialize and unseal each cluster:
  kubectl exec -n vault-a vault-a-0 -- vault operator init
  kubectl exec -n vault-b vault-b-0 -- vault operator init
EOF
