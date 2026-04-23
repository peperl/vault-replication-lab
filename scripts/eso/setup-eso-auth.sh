#!/usr/bin/env bash

# Wrapper script that gathers ESO cluster credentials and configures Vault A.
# This creates both Kubernetes and JWT auth backend roles, plus a Vault test secret.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="${SCRIPT_DIR}/vault_auth_config.py"

usage() {
  cat <<EOF
Usage: $0 --vault-url URL --vault-token TOKEN --vault-ca-file FILE [options]

Required:
  --vault-url URL            Vault A HTTPS API address for this script (usually https://127.0.0.1:32080)
  --vault-server-url URL     Vault A HTTPS URL for ESO pods to use (default: same as --vault-url)
  --vault-token TOKEN        Vault root/admin token
  --vault-ca-file FILE       Vault CA certificate file

Optional:
  --kube-context CONTEXT     kubeconfig context for ESO cluster (default: kind-vault-lab-eso)
  --kube-namespace NS        ESO namespace containing the service account (default: external-secrets)
  --kube-service-account SA  ESO service account used by the operator (default: external-secrets)
  --jwt-discovery-url URL    OIDC discovery URL accessible from Vault (default: derived from ESO cluster OIDC issuer)
  --jwt-client-id ID         JWT client ID (default: external-secrets)
  --jwt-audience AUD         JWT audience(s), comma-separated if multiple (default: vault,https://kubernetes.default.svc.cluster.local)
  --test-secret-path PATH    KV v2 path to write the test secret (default: secret/data/eso-test)
  --test-secret-key KEY      Secret data key (default: value)
  --test-secret-value VALUE  Secret data value (default: eso-test-value)
  --no-apply-manifests       Do not apply generated SecretStore/ExternalSecret manifests
  -h, --help                 Show this help message
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

VAULT_URL=""
VAULT_SERVER_URL=""
VAULT_TOKEN=""
VAULT_CA_FILE=""
KUBE_CONTEXT="kind-vault-lab-eso"
KUBE_NAMESPACE="external-secrets"
KUBE_SERVICE_ACCOUNT="external-secrets"
JWT_DISCOVERY_URL=""
JWT_CLIENT_ID="external-secrets"
JWT_AUDIENCE="vault,https://kubernetes.default.svc.cluster.local"
TEST_SECRET_PATH="secret/data/eso-test"
TEST_SECRET_KEY="value"
TEST_SECRET_VALUE="eso-test-value"
APPLY_MANIFESTS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault-url)
      VAULT_URL="$2"
      shift 2
      ;;
    --vault-server-url)
      VAULT_SERVER_URL="$2"
      shift 2
      ;;
    --vault-token)
      VAULT_TOKEN="$2"
      shift 2
      ;;
    --vault-ca-file)
      VAULT_CA_FILE="$2"
      shift 2
      ;;
    --kube-context)
      KUBE_CONTEXT="$2"
      shift 2
      ;;
    --kube-namespace)
      KUBE_NAMESPACE="$2"
      shift 2
      ;;
    --kube-service-account)
      KUBE_SERVICE_ACCOUNT="$2"
      shift 2
      ;;
    --jwt-discovery-url)
      JWT_DISCOVERY_URL="$2"
      shift 2
      ;;
    --jwt-client-id)
      JWT_CLIENT_ID="$2"
      shift 2
      ;;
    --jwt-audience)
      JWT_AUDIENCE="$2"
      shift 2
      ;;
    --test-secret-path)
      TEST_SECRET_PATH="$2"
      shift 2
      ;;
    --test-secret-key)
      TEST_SECRET_KEY="$2"
      shift 2
      ;;
    --test-secret-value)
      TEST_SECRET_VALUE="$2"
      shift 2
      ;;
    --no-apply-manifests)
      APPLY_MANIFESTS=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd python3
require_cmd kubectl
require_cmd base64

if [[ -z "${VAULT_URL}" || -z "${VAULT_TOKEN}" || -z "${VAULT_CA_FILE}" ]]; then
  echo "--vault-url, --vault-token, and --vault-ca-file are required." >&2
  usage
  exit 1
fi

if [[ -z "${VAULT_SERVER_URL}" ]]; then
  VAULT_SERVER_URL="${VAULT_URL}"
fi

if [[ ! -f "${VAULT_CA_FILE}" ]]; then
  echo "Vault CA file not found: ${VAULT_CA_FILE}" >&2
  exit 1
fi

KUBECTL_BASE=(kubectl --context "${KUBE_CONTEXT}")

# Get the token reviewer JWT from the target service account.
get_service_account_token() {
  local sa_name="${1:-${KUBE_SERVICE_ACCOUNT}}"
  if "${KUBECTL_BASE[@]}" create token "${sa_name}" -n "${KUBE_NAMESPACE}" >/dev/null 2>&1; then
    "${KUBECTL_BASE[@]}" create token "${sa_name}" -n "${KUBE_NAMESPACE}"
    return 0
  fi

  local secret_name
  secret_name="$(${KUBECTL_BASE[@]} -n "${KUBE_NAMESPACE}" get sa "${sa_name}" -o jsonpath='{.secrets[0].name}' 2>/dev/null || true)"
  if [[ -z "${secret_name}" ]]; then
    echo "Failed to find service account secret for ${sa_name}." >&2
    return 1
  fi
  "${KUBECTL_BASE[@]} -n "${KUBE_NAMESPACE}" get secret "${secret_name}" -o jsonpath='{.data.token}' | base64 --decode"
}



if ! "${KUBECTL_BASE[@]}" get namespace "${KUBE_NAMESPACE}" >/dev/null 2>&1; then
  echo "Namespace ${KUBE_NAMESPACE} does not exist in context ${KUBE_CONTEXT}." >&2
  exit 1
fi

mkdir -p "${SCRIPT_DIR}/tmp"
TEMP_DIR="$(mktemp -d "${SCRIPT_DIR}/tmp/eso-XXXXXX")"
# trap 'rm -rf "${TEMP_DIR}"' EXIT  # Commented out to preserve temporary files for debugging

JWT_JWKS_FILE="${TEMP_DIR}/jwks.json"
OIDC_CONFIG_FILE="${TEMP_DIR}/oidc.json"

# Extract the ESO cluster OIDC issuer and JWKS from the API server.
"${KUBECTL_BASE[@]}" get --raw '/.well-known/openid-configuration' > "${OIDC_CONFIG_FILE}"
"${KUBECTL_BASE[@]}" get --raw '/openid/v1/jwks' > "${JWT_JWKS_FILE}"
OIDC_ISSUER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["issuer"])' "${OIDC_CONFIG_FILE}")"

if [[ -z "${JWT_DISCOVERY_URL}" ]]; then
  JWT_DISCOVERY_URL="${OIDC_ISSUER}/.well-known/openid-configuration"
fi

python3 "${PYTHON_SCRIPT}" \
  --vault-url "${VAULT_URL}" \
  --vault-token "${VAULT_TOKEN}" \
  --vault-ca-file "${VAULT_CA_FILE}" \
  --jwt-jwks-file "${JWT_JWKS_FILE}" \
  --jwt-client-id "${JWT_CLIENT_ID}" \
  --jwt-audience "${JWT_AUDIENCE}" \
  --kube-issuer "${OIDC_ISSUER}" \
  --test-secret-path "${TEST_SECRET_PATH}" \
  --test-secret-key "${TEST_SECRET_KEY}" \
  --test-secret-value "${TEST_SECRET_VALUE}"

if [[ "${APPLY_MANIFESTS}" -eq 1 ]]; then
  echo "Applying ESO SecretStore and ExternalSecret manifests for a final test..."
  
  cat > "${SCRIPT_DIR}/vault-a-jwt-store.yaml" <<EOF
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault-a-jwt-store
  namespace: ${KUBE_NAMESPACE}
spec:
  provider:
    vault:
      server: ${VAULT_SERVER_URL}
      path: secret
      version: v2
      caProvider:
        type: Secret
        name: vault-a-ca
        key: ca.crt
      auth:
        jwt:
          path: jwt
          role: external-secrets-jwt
          kubernetesServiceAccountToken:
            serviceAccountRef:
              name: ${KUBE_SERVICE_ACCOUNT}
              namespace: ${KUBE_NAMESPACE}
            audiences:
EOF
  IFS=',' read -ra JWT_AUDIENCES <<< "${JWT_AUDIENCE}"
  for aud in "${JWT_AUDIENCES[@]}"; do
    aud="${aud## }"
    aud="${aud%% }"
    printf '              - %s\n' "${aud}" >> "${SCRIPT_DIR}/vault-a-jwt-store.yaml"
  done
  cat >> "${SCRIPT_DIR}/vault-a-jwt-store.yaml" <<EOF
EOF

  cat > "${SCRIPT_DIR}/eso-test-externalsecret.yaml" <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: eso-test-secret
  namespace: ${KUBE_NAMESPACE}
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: vault-a-jwt-store
    kind: SecretStore
  target:
    name: eso-test-secret
    creationPolicy: Owner
  data:
    - secretKey: ${TEST_SECRET_KEY}
      remoteRef:
        key: ${TEST_SECRET_PATH}
        property: ${TEST_SECRET_KEY}
EOF

  kubectl --context "${KUBE_CONTEXT}" apply -n "${KUBE_NAMESPACE}" -f "${SCRIPT_DIR}/vault-a-jwt-store.yaml"
  kubectl --context "${KUBE_CONTEXT}" apply -n "${KUBE_NAMESPACE}" -f "${SCRIPT_DIR}/eso-test-externalsecret.yaml"
  echo "Applied test manifests."
fi

cat <<EOF
ESO Vault connection setup complete.
- Vault URL: ${VAULT_URL}
- Test secret created at: ${TEST_SECRET_PATH}
- SecretStore manifest: ${SCRIPT_DIR}/vault-a-jwt-store.yaml
- ExternalSecret manifest: ${SCRIPT_DIR}/eso-test-externalsecret.yaml
EOF
