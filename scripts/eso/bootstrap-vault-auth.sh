#!/usr/bin/env bash

# Configure Vault A with auth methods for the External Secrets Operator.
# This script enables both Kubernetes auth and JWT auth on the Vault A cluster,
# then creates policies and roles for the ESO workloads.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIND_CONTEXT="kind-vault-lab"
SECRETS_DIR="${ROOT_DIR}/secrets"
VAULT_INIT_FILE="${SECRETS_DIR}/vault-a-init.json"
LOCAL_VAULT_ADDR="https://127.0.0.1:8200"
VAULT_CACERT_PATH="/vault/userconfig/tls/ca.crt"
POD="vault-a-0"

# Fail if any required CLI tool is missing.
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd kubectl
require_cmd jq

# Ensure the Vault init file exists so we can authenticate as root.
if [[ ! -f "${VAULT_INIT_FILE}" ]]; then
  echo "Vault init file not found: ${VAULT_INIT_FILE}" >&2
  echo "Run ./scripts/bootstrap.sh for vault-a first and ensure the secrets file exists." >&2
  exit 1
fi

VAULT_ROOT_TOKEN="$(jq -r '.root_token' "${VAULT_INIT_FILE}")"
if [[ -z "${VAULT_ROOT_TOKEN}" || "${VAULT_ROOT_TOKEN}" == "null" ]]; then
  echo "Unable to read root token from ${VAULT_INIT_FILE}." >&2
  exit 1
fi

# Ensure we are operating against the Vault cluster context.
CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
if [[ "${CURRENT_CONTEXT}" != "${KIND_CONTEXT}" ]]; then
  echo "Current kubectl context is '${CURRENT_CONTEXT:-<none>}'" >&2
  echo "Switch to '${KIND_CONTEXT}' first, or create it with ./scripts/create-kind-cluster.sh." >&2
  exit 1
fi

# Helper wrapper to execute Vault CLI inside the Vault pod.
# The -i flag forwards stdin so piped policy text is delivered correctly.
vault_exec() {
  kubectl exec -n vault-a -i "${POD}" -- env \
    VAULT_ADDR="${LOCAL_VAULT_ADDR}" \
    VAULT_CACERT="${VAULT_CACERT_PATH}" \
    VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
    "$@"
}

# Verify the Vault pod exists before continuing.
if ! kubectl get pod -n vault-a "${POD}" >/dev/null 2>&1; then
  echo "Vault pod ${POD} not found in namespace vault-a." >&2
  exit 1
fi

# Enable Kubernetes auth if it is not already enabled.
if ! vault_exec vault auth list -format=json | jq -e 'has("kubernetes/")' >/dev/null 2>&1; then
  echo "Enabling Kubernetes auth on Vault A..."
  vault_exec vault auth enable kubernetes
else
  echo "Kubernetes auth already enabled."
fi

# Use the pod's service account token and CA for auth configuration.
KUBE_REVIEWER_JWT="$(kubectl exec -n vault-a "${POD}" -- cat /var/run/secrets/kubernetes.io/serviceaccount/token | tr -d '\n')"
KUBE_CA_CERT="$(kubectl exec -n vault-a "${POD}" -- cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)"

vault_exec vault write auth/kubernetes/config \
  token_reviewer_jwt="${KUBE_REVIEWER_JWT}" \
  kubernetes_host="https://kubernetes.default.svc" \
  kubernetes_ca_cert="${KUBE_CA_CERT}" \
  issuer="https://kubernetes.default.svc"

# Create a policy that allows reading secrets from the data paths.
cat <<'EOF' | vault_exec vault policy write external-secrets-policy -
path "secret/data/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/*" {
  capabilities = ["list"]
}
EOF

# Create a Kubernetes auth role for the External Secrets operator.
vault_exec vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets-operator \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets-policy \
  token_ttl=1h

# Enable JWT auth if not already enabled.
if ! vault_exec vault auth list -format=json | jq -e 'has("jwt/")' >/dev/null 2>&1; then
  echo "Enabling JWT auth on Vault A..."
  vault_exec vault auth enable jwt
else
  echo "JWT auth already enabled."
fi

# Configure JWT auth; may require additional manual tuning depending on the issuer.
set +e
vault_exec vault write auth/jwt/config \
  oidc_discovery_url="https://kubernetes.default.svc/.well-known/openid-configuration" \
  oidc_client_id="external-secrets" >/dev/null 2>&1
if [[ $? -ne 0 ]]; then
  echo "Warning: auth/jwt mount enabled, but OIDC discovery config failed."
  echo "If your cluster does not expose OIDC discovery, configure auth/jwt manually after bootstrap."
fi
set -e

# Create a JWT auth role for the External Secrets operator.
vault_exec vault write auth/jwt/role/external-secrets-jwt \
  role_type="jwt" \
  bound_audiences="external-secrets" \
  user_claim="sub" \
  policies="external-secrets-policy" \
  token_ttl="1h"

cat <<EOF
Vault A auth configuration complete.

Enabled auth methods:
  - auth/kubernetes (role: external-secrets)
  - auth/jwt (role: external-secrets-jwt)

Policy created: external-secrets-policy

If JWT auth config failed, review auth/jwt/config and set the correct issuer or public key details.
EOF
