# HTTPie Desktop Collections

This folder contains Postman-format collections that HTTPie Desktop can import.

Files:

- `vault-a.postman_collection.json`
- `vault-b.postman_collection.json`

Each collection already includes:

- the correct local base URL
- the current root token for that Vault cluster

Import in HTTPie Desktop:

1. Open HTTPie Desktop.
2. Use the import action.
3. Select one or both `*.postman_collection.json` files from this folder.

Security note:

- These files contain active root tokens.
- Treat them like secrets.
- If you share this workspace, rotate the tokens or reinitialize the clusters.


TLS note:

- The collections now use `https://127.0.0.1:32080` and `https://127.0.0.1:32081`.
- Trust `../secrets/vault-lab-ca.crt` in your OS or HTTPie Desktop before using them.
