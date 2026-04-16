#!/usr/bin/env bash

# Create a dedicated kind cluster for the External Secrets Operator.
# This cluster is separate from the Vault cluster and will be used
# to run ESO workloads that authenticate to Vault A.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="vault-lab-eso"

# Create the cluster from the dedicated config file.
kind create cluster --name "${CLUSTER_NAME}" --config "${ROOT_DIR}/kind-config-eso.yaml"

# Switch kubectl to the new ESO cluster context.
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

cat <<'EOF'
kind cluster created.

Context: kind-vault-lab-eso

Next step:
  ./scripts/eso/bootstrap-vault-auth.sh
  ./scripts/eso/install-external-secrets.sh
EOF
