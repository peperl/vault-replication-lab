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
SECRETS_DIR="${ROOT_DIR}/secrets"

helm uninstall vault-a -n vault-a || true
helm uninstall vault-b -n vault-b || true
kubectl delete -f "${ROOT_DIR}/manifests/vault/certificates.yaml" --ignore-not-found=true || true
kubectl delete -f "${ROOT_DIR}/manifests/cert-manager/cluster-issuer.yaml" --ignore-not-found=true || true
kubectl delete namespace vault-a vault-b --ignore-not-found=true || true
kubectl delete -k "${ROOT_DIR}/manifests/cert-manager" --ignore-not-found=true || true
rm -rf "${SECRETS_DIR}"
