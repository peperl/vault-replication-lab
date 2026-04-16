#!/usr/bin/env bash

# Delete the dedicated External Secrets Operator kind cluster.
# Use this when you want to remove the ESO test environment.

set -euo pipefail

kind delete cluster --name vault-lab-eso
