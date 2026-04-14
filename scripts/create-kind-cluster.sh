#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="vault-lab"

kind create cluster --name "${CLUSTER_NAME}" --config "${ROOT_DIR}/kind-config.yaml"
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

cat <<'EOF'
kind cluster created.

Context: kind-vault-lab
Vault UI host ports:
  http://127.0.0.1:32080
  http://127.0.0.1:32081

Next step:
  ./scripts/install.sh
EOF
