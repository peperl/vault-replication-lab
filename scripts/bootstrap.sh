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
KIND_CONTEXT="kind-vault-lab"
SECRETS_DIR="${ROOT_DIR}/secrets"
VAULT_CACERT_PATH="/vault/userconfig/tls/ca.crt"
VAULT_CLIENT_CERT_PATH="/vault/userconfig/tls/tls.crt"
VAULT_CLIENT_KEY_PATH="/vault/userconfig/tls/tls.key"
LOCAL_VAULT_ADDR="https://127.0.0.1:8200"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

vault_cli() {
  local namespace="$1"
  local pod="$2"
  shift 2
  kubectl exec -n "${namespace}" "${pod}" -- env     VAULT_ADDR="${LOCAL_VAULT_ADDR}"     VAULT_CACERT="${VAULT_CACERT_PATH}"     "$@"
}

raft_join() {
  local namespace="$1"
  local pod="$2"
  local join_addr="$3"

  kubectl exec -n "${namespace}" "${pod}" -- env     VAULT_ADDR="${LOCAL_VAULT_ADDR}"     VAULT_CACERT_FILE="${VAULT_CACERT_PATH}"     VAULT_CLIENT_CERT_FILE="${VAULT_CLIENT_CERT_PATH}"     VAULT_CLIENT_KEY_FILE="${VAULT_CLIENT_KEY_PATH}"     JOIN_ADDR="${join_addr}"     sh -ec 'vault operator raft join       -address="$VAULT_ADDR"       -leader-ca-cert="$(cat "$VAULT_CACERT_FILE")"       -leader-client-cert="$(cat "$VAULT_CLIENT_CERT_FILE")"       -leader-client-key="$(cat "$VAULT_CLIENT_KEY_FILE")"       "$JOIN_ADDR"'
}

wait_for_pod() {
  local namespace="$1"
  local pod="$2"
  echo "Waiting for ${namespace}/${pod} to be Running..."
  until [[ "$(kubectl get pod -n "${namespace}" "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || true)" == "Running" ]]; do
    sleep 2
  done
}

retry_unseal() {
  local namespace="$1"
  local pod="$2"
  local unseal_key="$3"
  local attempts=30
  local i

  for ((i=1; i<=attempts; i++)); do
    if [[ "$(vault_sealed "${namespace}" "${pod}")" == "false" ]]; then
      return 0
    fi

    echo "Unseal attempt ${i}/${attempts} for ${namespace}/${pod}..."
    { set +x; } 2>/dev/null
    if vault_cli "${namespace}" "${pod}" vault operator unseal "${unseal_key}"; then
      set -x
      if [[ "$(vault_sealed "${namespace}" "${pod}")" == "false" ]]; then
        return 0
      fi
    else
      set -x
    fi

    sleep 2
  done

  echo "Timed out unsealing ${namespace}/${pod}." >&2
  return 1
}

vault_field() {
  local namespace="$1"
  local pod="$2"
  local field="$3"
  local fallback="$4"
  local output

  output="$(vault_cli "${namespace}" "${pod}" vault status -format=json 2>/dev/null || true)"
  if [[ -z "${output}" ]]; then
    echo "${fallback}"
    return 0
  fi

  jq -r --arg field "${field}" '.[$field]' <<<"${output}" 2>/dev/null || echo "${fallback}"
}

vault_initialized() {
  local namespace="$1"
  local pod="$2"
  vault_field "${namespace}" "${pod}" initialized false
}

vault_sealed() {
  local namespace="$1"
  local pod="$2"
  vault_field "${namespace}" "${pod}" sealed true
}

bootstrap_cluster() {
  local namespace="$1"
  local release="$2"
  local leader_pod="${release}-0"
  local follower_1="${release}-1"
  local follower_2="${release}-2"
  local init_file="${SECRETS_DIR}/${release}-init.json"
  local join_addr="https://${leader_pod}.${release}-internal:8200"

  wait_for_pod "${namespace}" "${leader_pod}"
  wait_for_pod "${namespace}" "${follower_1}"
  wait_for_pod "${namespace}" "${follower_2}"

  local initialized_now="false"
  if [[ "$(vault_initialized "${namespace}" "${leader_pod}")" != "true" ]]; then
    if [[ -e "${init_file}" ]]; then
      echo "Refusing to overwrite existing ${init_file}. Remove it or re-run against a fresh cluster." >&2
      exit 1
    fi

    echo "Initializing ${release} with key-shares=1 and key-threshold=1..."
    vault_cli "${namespace}" "${leader_pod}"       vault operator init -format=json -key-shares=1 -key-threshold=1 > "${init_file}"
    chmod 600 "${init_file}"
    initialized_now="true"
  else
    if [[ ! -e "${init_file}" ]]; then
      echo "${release} is already initialized but ${init_file} is missing." >&2
      echo "Create the file manually or redeploy the cluster before using this script." >&2
      exit 1
    fi
    echo "${release} is already initialized. Reusing ${init_file}."
  fi

  local unseal_key
  unseal_key="$(jq -r '.unseal_keys_hex[0]' "${init_file}")"

  if [[ "${initialized_now}" == "true" ]]; then
    echo "Unsealing ${leader_pod} immediately after init..."
    retry_unseal "${namespace}" "${leader_pod}" "${unseal_key}"
  elif [[ "$(vault_sealed "${namespace}" "${leader_pod}")" == "true" ]]; then
    echo "Unsealing ${leader_pod}..."
    retry_unseal "${namespace}" "${leader_pod}" "${unseal_key}"
  fi

  for pod in "${follower_1}" "${follower_2}"; do
    if [[ "$(vault_initialized "${namespace}" "${pod}")" != "true" ]]; then
      echo "Joining ${pod} to ${leader_pod}..."
      raft_join "${namespace}" "${pod}" "${join_addr}"
    fi

    if [[ "$(vault_sealed "${namespace}" "${pod}")" == "true" ]]; then
      echo "Unsealing ${pod}..."
      retry_unseal "${namespace}" "${pod}" "${unseal_key}"
    fi
  done

  echo "${release} bootstrap complete."
}

require_cmd kubectl
require_cmd jq

current_context="$(kubectl config current-context 2>/dev/null || true)"
if [[ "${current_context}" != "${KIND_CONTEXT}" ]]; then
  echo "Current kubectl context is '${current_context:-<none>}'" >&2
  echo "Switch to '${KIND_CONTEXT}' first, or create it with ./scripts/create-kind-cluster.sh." >&2
  exit 1
fi

mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"

bootstrap_cluster vault-a vault-a
bootstrap_cluster vault-b vault-b

cat <<'EOF'
Bootstrap complete.

Init files:
  secrets/vault-a-init.json
  secrets/vault-b-init.json

APIs:
  https://127.0.0.1:32080
  https://127.0.0.1:32081
EOF
