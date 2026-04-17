# Local Dual Vault HA Deployment on kind

This workspace deploys two separate HashiCorp Vault clusters into a dedicated multi-node `kind` cluster using the official Helm chart.

Pinned versions:

- Vault Helm chart: `0.32.0`
- Vault server image: `1.21.2`
- cert-manager static install: `v1.20.0`

The `kind` cluster created here uses:

- `1` control-plane node
- `3` worker nodes
- Host port mappings for Vault UIs on `32080` and `32081`

Vault clusters:

- `vault-a` namespace, UI/API on `https://127.0.0.1:32080`
- `vault-b` namespace, UI/API on `https://127.0.0.1:32081`

Both Vault clusters use:

- HashiCorp Vault, not OpenBao
- Integrated Raft storage
- `3` server replicas each
- Default Helm anti-affinity enabled so pods spread across kind nodes
- cert-manager-issued TLS certificates signed by a local self-signed CA
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

## TLS assets

`install.sh` deploys cert-manager, creates a local CA `ClusterIssuer`, issues per-cluster certificates, and exports the CA certificate to:

```bash
secrets/vault-lab-ca.crt
```

Use that CA file with local clients, for example:

```bash
curl --cacert secrets/vault-lab-ca.crt https://127.0.0.1:32080/v1/sys/health
curl --cacert secrets/vault-lab-ca.crt https://127.0.0.1:32081/v1/sys/health
```

## Check status

```bash
kubectl get nodes -o wide
kubectl get pods -n vault-a -o wide
kubectl get pods -n vault-b -o wide
kubectl get svc -n vault-a
kubectl get svc -n vault-b
kubectl get certificate -n vault-a
kubectl get certificate -n vault-b
```

## Bootstrap details

`bootstrap.sh` now performs Vault operations over HTTPS from inside each pod, using the mounted cert-manager CA bundle. The flow is:

1. Initialize `vault-*-0` with `key-shares=1` and `key-threshold=1`.
2. Unseal `vault-*-0`.
3. Join `vault-*-1` and `vault-*-2` to the leader over `https://vault-*-0.<release>-internal:8200`, passing the mounted CA, client certificate, and client key to `vault operator raft join`.
4. Unseal the follower pods.

The init outputs are stored in:

```bash
secrets/vault-a-init.json
secrets/vault-b-init.json
```

## Access the UIs

- Cluster A: `https://127.0.0.1:32080`
- Cluster B: `https://127.0.0.1:32081`

Because the certs are signed by the local CA created for this lab, your browser or API client must trust `secrets/vault-lab-ca.crt`.

## External Secrets operator cluster

This workspace now supports a separate operator cluster for External Secrets, which can connect to Vault A.

1. Create the operator cluster:

```bash
./scripts/eso/create-kind-cluster-eso.sh
```

2. Install the External Secrets operator into the new cluster:

```bash
kubectl config use-context kind-vault-lab-eso
./scripts/eso/install-external-secrets.sh
```

3. Configure Vault A for ESO cross-cluster authentication and create a test secret:

```bash
kubectl config use-context kind-vault-lab
./scripts/eso/setup-eso-auth.sh \
  --vault-url https://host.docker.internal:32080 \
  --vault-token "$(jq -r '.root_token' secrets/vault-a-init.json)" \
  --vault-ca-file secrets/vault-lab-ca.crt
```

The script will enable both Vault auth methods, write a test secret, and generate SecretStore/ExternalSecret manifests for the ESO cluster.

## Remove everything

```bash
./scripts/uninstall.sh
./scripts/delete-kind-cluster.sh
./scripts/eso/delete-kind-cluster-eso.sh
```

## Notes

- This setup assumes a real multi-node `kind` cluster so the Vault chart can keep its HA anti-affinity.
- The CA is self-signed for local development only.
- Each cluster gets its own PVC-backed Raft data store.
- If your kind cluster does not have a default `StorageClass`, the Vault PVCs will remain pending until one is installed.
