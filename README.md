# Local Dual Vault HA Deployment on kind

This workspace deploys two separate HashiCorp Vault clusters into a dedicated multi-node `kind` cluster using the official Helm chart.

Pinned versions:

- Vault Helm chart: `0.32.0`
- Vault server image: `1.21.2`

The `kind` cluster created here uses:

- `1` control-plane node
- `3` worker nodes
- Host port mappings for Vault UIs on `32080` and `32081`

Vault clusters:

- `vault-a` namespace, UI/API on `http://127.0.0.1:32080`
- `vault-b` namespace, UI/API on `http://127.0.0.1:32081`

Both Vault clusters use:

- HashiCorp Vault, not OpenBao
- Integrated Raft storage
- `3` server replicas each
- Default Helm anti-affinity enabled so pods spread across kind nodes
- Disabled injector and CSI components to keep the local footprint smaller

## Create the kind cluster

```bash
./scripts/create-kind-cluster.sh
```

This creates a cluster named `vault-lab` and switches `kubectl` to the `kind-vault-lab` context.

## Deploy Vault

```bash
./scripts/install.sh
./scripts/bootstrap.sh
```

Optional verbose mode:

```bash
VERBOSE=1 ./scripts/install.sh
VERBOSE=1 ./scripts/bootstrap.sh
VERBOSE=1 ./scripts/uninstall.sh
```

## Check status

```bash
kubectl get nodes -o wide
kubectl get pods -n vault-a -o wide
kubectl get pods -n vault-b -o wide
kubectl get svc -n vault-a
kubectl get svc -n vault-b
```

## Initialize, join, and unseal

Initialize only the first pod in each cluster:

```bash
kubectl exec -n vault-a vault-a-0 -- vault operator init
kubectl exec -n vault-b vault-b-0 -- vault operator init
```

Save the unseal keys and initial root token somewhere secure.

Unseal the first pod in each cluster with enough keys to satisfy the threshold returned by `vault operator init`:

```bash
kubectl exec -n vault-a vault-a-0 -- vault operator unseal
kubectl exec -n vault-a vault-a-0 -- vault operator unseal
kubectl exec -n vault-a vault-a-0 -- vault operator unseal

kubectl exec -n vault-b vault-b-0 -- vault operator unseal
kubectl exec -n vault-b vault-b-0 -- vault operator unseal
kubectl exec -n vault-b vault-b-0 -- vault operator unseal
```

Join the remaining pods to the Raft leader:

```bash
kubectl exec -n vault-a vault-a-1 -- vault operator raft join http://vault-a-0.vault-a-internal:8200
kubectl exec -n vault-a vault-a-2 -- vault operator raft join http://vault-a-0.vault-a-internal:8200

kubectl exec -n vault-b vault-b-1 -- vault operator raft join http://vault-b-0.vault-b-internal:8200
kubectl exec -n vault-b vault-b-2 -- vault operator raft join http://vault-b-0.vault-b-internal:8200
```

Then unseal the joined follower pods:

```bash
kubectl exec -n vault-a vault-a-1 -- vault operator unseal
kubectl exec -n vault-a vault-a-1 -- vault operator unseal
kubectl exec -n vault-a vault-a-1 -- vault operator unseal
kubectl exec -n vault-a vault-a-2 -- vault operator unseal
kubectl exec -n vault-a vault-a-2 -- vault operator unseal
kubectl exec -n vault-a vault-a-2 -- vault operator unseal

kubectl exec -n vault-b vault-b-1 -- vault operator unseal
kubectl exec -n vault-b vault-b-1 -- vault operator unseal
kubectl exec -n vault-b vault-b-1 -- vault operator unseal
kubectl exec -n vault-b vault-b-2 -- vault operator unseal
kubectl exec -n vault-b vault-b-2 -- vault operator unseal
kubectl exec -n vault-b vault-b-2 -- vault operator unseal
```

At the end, each cluster should have one active leader and two standby followers.

## Access the UIs

- Cluster A: `http://127.0.0.1:32080`
- Cluster B: `http://127.0.0.1:32081`

## Remove everything

```bash
./scripts/uninstall.sh
./scripts/delete-kind-cluster.sh
```

## Notes

- This setup assumes a real multi-node `kind` cluster so the Vault chart can keep its HA anti-affinity.
- TLS is disabled for local development convenience.
- Each cluster gets its own PVC-backed Raft data store.
- If your kind cluster does not have a default `StorageClass`, the Vault PVCs will remain pending until one is installed.
