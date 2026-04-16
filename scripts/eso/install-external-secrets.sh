#!/usr/bin/env bash

# Install the External Secrets Operator into the dedicated ESO cluster.
# This script deploys the chart, creates the operator namespace, and
# stores the Vault CA certificate for TLS verification.

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
KIND_CONTEXT="kind-vault-lab-eso"
SECRETS_DIR="${ROOT_DIR}/secrets"

# Helper to ensure required CLI tools are available.
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd kubectl
require_cmd helm

# Validate that kubectl is pointing at the ESO cluster.
CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
if [[ "${CURRENT_CONTEXT}" != "${KIND_CONTEXT}" ]]; then
  echo "Current kubectl context is '${CURRENT_CONTEXT:-<none>}'" >&2
  echo "Switch to '${KIND_CONTEXT}' first, or create it with ./scripts/eso/create-kind-cluster-eso.sh." >&2
  exit 1
fi

# Create the external-secrets namespace before install.
kubectl apply -f "${ROOT_DIR}/manifests/external-secrets/namespace.yaml"

# Deploy the External Secrets Operator Helm chart.
helm repo add external-secrets https://charts.external-secrets.io || true
helm repo update
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set installCRDs=true \
  --wait \
  --timeout 5m

# Ensure the Vault CA is available locally from the Vault cluster install.
if [[ ! -f "${SECRETS_DIR}/vault-lab-ca.crt" ]]; then
  echo "Vault CA certificate not found: ${SECRETS_DIR}/vault-lab-ca.crt" >&2
  echo "Run ./scripts/install.sh and ./scripts/bootstrap.sh in the Vault cluster first." >&2
  exit 1
fi

# Create a Kubernetes secret in the ESO cluster containing the Vault CA.
kubectl create secret generic vault-a-ca -n external-secrets \
  --from-file=ca.crt="${SECRETS_DIR}/vault-lab-ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF
External Secrets operator installed in the kind-vault-lab-eso cluster.

Namespace: external-secrets
Vault A address: https://host.docker.internal:32080
Vault CA secret: vault-a-ca

Next step:
  Create SecretStore definitions in the external-secrets namespace that point to Vault A
  and use auth.kubernetes or auth.jwt.
EOF
