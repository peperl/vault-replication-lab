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
SECRETS_DIR="${ROOT_DIR}/secrets"
CA_FILE="${SECRETS_DIR}/vault-lab-ca.crt"

wait_for_rollout() {
  local namespace="$1"
  local deployment="$2"
  kubectl rollout status deployment/"${deployment}" -n "${namespace}" --timeout=5m
}

mkdir -p "${HELM_CONFIG_HOME}" "${HELM_CACHE_HOME}" "${HELM_DATA_HOME}" "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"

CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
if [[ "${CURRENT_CONTEXT}" != "${KIND_CONTEXT}" ]]; then
  echo "Current kubectl context is '${CURRENT_CONTEXT:-<none>}'" >&2
  echo "Switch to '${KIND_CONTEXT}' first, or create it with ./scripts/create-kind-cluster.sh." >&2
  exit 1
fi

kubectl apply -f "${ROOT_DIR}/namespaces.yaml"

kubectl apply -k "${ROOT_DIR}/manifests/cert-manager"
wait_for_rollout cert-manager cert-manager
wait_for_rollout cert-manager cert-manager-cainjector
wait_for_rollout cert-manager cert-manager-webhook

kubectl apply -f "${ROOT_DIR}/manifests/cert-manager/cluster-issuer.yaml"
kubectl wait --for=condition=Ready certificate/vault-lab-root-ca -n cert-manager --timeout=5m

kubectl apply -f "${ROOT_DIR}/manifests/vault/certificates.yaml"
kubectl wait --for=condition=Ready certificate/vault-a-tls -n vault-a --timeout=5m
kubectl wait --for=condition=Ready certificate/vault-b-tls -n vault-b --timeout=5m
kubectl get secret -n cert-manager vault-lab-root-ca -o jsonpath='{.data.tls\.crt}' | base64 --decode > "${CA_FILE}"
chmod 600 "${CA_FILE}"

helm repo add "${CHART_REPO}" https://helm.releases.hashicorp.com || true
helm repo update

helm upgrade --install vault-a "${CHART_REPO}/${CHART_NAME}"   --namespace vault-a   --version "${CHART_VERSION}"   --values "${ROOT_DIR}/values/vault-cluster-a.yaml"   --wait   --timeout 15m

helm upgrade --install vault-b "${CHART_REPO}/${CHART_NAME}"   --namespace vault-b   --version "${CHART_VERSION}"   --values "${ROOT_DIR}/values/vault-cluster-b.yaml"   --wait   --timeout 15m

cat <<EOF
Vault clusters deployed with TLS.

Cluster A UI/API: https://127.0.0.1:32080
Cluster B UI/API: https://127.0.0.1:32081
CA certificate: ${CA_FILE}

Next step:
  ./scripts/bootstrap.sh
EOF
