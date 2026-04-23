#!/usr/bin/env python3
import argparse
import base64
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request


def parse_args():
    parser = argparse.ArgumentParser(
        description="Configure Vault auth methods for External Secrets Operator."
    )
    parser.add_argument("--vault-url", required=True, help="Vault HTTPS URL")
    parser.add_argument("--vault-token", required=True, help="Vault root/admin token")
    parser.add_argument("--vault-ca-file", required=True, help="Path to Vault CA certificate")
    parser.add_argument("--jwt-discovery-url", required=False, help="OIDC discovery URL reachable from Vault")
    parser.add_argument("--jwt-jwks-url", required=False, help="JWKS URL reachable from Vault")
    parser.add_argument("--jwt-jwks-file", required=False, help="Path to a local JWKS JSON file")
    parser.add_argument("--jwt-client-id", default="external-secrets", help="JWT client ID (not used for JWKS-based validation)")
    parser.add_argument("--jwt-audience", default="vault,https://kubernetes.default.svc.cluster.local", help="Expected JWT audience(s), comma-separated if multiple")
    parser.add_argument("--jwt-role-name", default="external-secrets-jwt", help="Vault JWT auth role name")
    parser.add_argument("--kube-issuer", required=False, help="Expected JWT issuer (OIDC issuer)")
    parser.add_argument("--policy-name", default="external-secrets-policy", help="Vault policy name")
    parser.add_argument("--test-secret-path", default="secret/data/eso-test", help="Vault KV v2 path for the test secret")
    parser.add_argument("--test-secret-key", default="value", help="Test secret key")
    parser.add_argument("--test-secret-value", default="eso-test-value", help="Test secret value")
    return parser.parse_args()


def load_file(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def build_url(base, endpoint):
    base = base.rstrip("/")
    endpoint = endpoint.lstrip("/")
    return f"{base}/{endpoint}"


def vault_request(method, url, token, payload=None, ca_file=None):
    headers = {
        "X-Vault-Token": token,
        "Content-Type": "application/json",
    }
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    ctx = ssl.create_default_context()
    ctx.check_hostname = True
    if ca_file:
        ctx.load_verify_locations(cafile=ca_file)
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=ctx) as resp:
            body = resp.read().decode("utf-8")
            if body:
                return json.loads(body)
            return {}
    except urllib.error.HTTPError as exc:
        message = exc.read().decode("utf-8")
        raise RuntimeError(f"Vault API error {exc.code} {exc.reason}: {message}")
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Vault connection error: {exc}")


def auth_enabled(vault_url, token, ca_file, mount):
    data = vault_request("GET", build_url(vault_url, "v1/sys/auth"), token, ca_file=ca_file)
    return mount.rstrip("/") + "/" in data


def enable_auth(vault_url, token, ca_file, mount, auth_type):
    if auth_enabled(vault_url, token, ca_file, mount):
        print(f"Auth method '{mount}' already enabled.")
        return
    print(f"Enabling auth method '{mount}' of type '{auth_type}'.")
    vault_request("POST", build_url(vault_url, f"v1/sys/auth/{mount}"), token, payload={"type": auth_type}, ca_file=ca_file)


def write_policy(vault_url, token, ca_file, policy_name):
    print(f"Writing Vault policy '{policy_name}'.")
    policy = '''path "secret/data/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/*" {
  capabilities = ["list"]
}
'''
    vault_request("PUT", build_url(vault_url, f"v1/sys/policies/acl/{policy_name}"), token, payload={"policy": policy}, ca_file=ca_file)


def ensure_kv_engine(vault_url, token, ca_file, mount="secret", version=2):
    mounts = vault_request("GET", build_url(vault_url, "v1/sys/mounts"), token, ca_file=ca_file)
    if mount.rstrip("/") + "/" in mounts:
        print(f"KV engine '{mount}' already enabled.")
        return
    print(f"Enabling KV v{version} engine at '{mount}'.")
    payload = {"type": "kv", "options": {"version": str(version)}}
    vault_request("POST", build_url(vault_url, f"v1/sys/mounts/{mount}"), token, payload=payload, ca_file=ca_file)


def fetch_jwks_from_url(jwks_url, ca_file):
    print(f"Fetching JWKS from: {jwks_url}")
    data = vault_request("GET", jwks_url, token="", ca_file=ca_file)
    if "keys" not in data:
        raise RuntimeError("JWKS response did not contain 'keys'.")
    return data["keys"]


def load_jwks_file(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if "keys" not in data:
        raise RuntimeError("JWKS file did not contain 'keys'.")
    return data["keys"]


def int_from_base64url(value):
    padding = "=" * ((4 - len(value) % 4) % 4)
    data = base64.urlsafe_b64decode(value + padding)
    return int.from_bytes(data, "big")


def der_length(data):
    if len(data) < 128:
        return bytes([len(data)])
    length = len(data)
    size = []
    while length > 0:
        size.append(length & 0xFF)
        length >>= 8
    return bytes([0x80 | len(size)]) + bytes(reversed(size))


def der_integer(number):
    data = number.to_bytes((number.bit_length() + 7) // 8 or 1, "big")
    if data[0] & 0x80:
        data = b"\x00" + data
    return b"\x02" + der_length(data) + data


def rsa_public_key_pem(n, e):
    modulus = der_integer(n)
    exponent = der_integer(e)
    seq = b"\x30" + der_length(modulus + exponent) + modulus + exponent
    bit_string = b"\x03" + der_length(b"\x00" + seq) + b"\x00" + seq
    oid = b"\x30\x0d\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01\x05\x00"
    spki = b"\x30" + der_length(oid + bit_string) + oid + bit_string
    pem = b"-----BEGIN PUBLIC KEY-----\n"
    pem += base64.encodebytes(spki)
    pem += b"-----END PUBLIC KEY-----\n"
    return pem.decode("ascii")


def jwks_to_pem(keys):
    for key in keys:
        if key.get("kty") == "RSA" and key.get("n") and key.get("e"):
            n = int_from_base64url(key["n"])
            e = int_from_base64url(key["e"])
            return rsa_public_key_pem(n, e)
    raise RuntimeError("No RSA key found in JWKS.")


def configure_jwt(vault_url, token, ca_file, mount, discovery_url, jwks_url, jwks_file, client_id, kube_ca_file=None):
    print("Configuring JWT auth backend.")
    if not jwks_file and not jwks_url and not discovery_url:
        raise RuntimeError("Either --jwt-jwks-file, --jwt-jwks-url, or --jwt-discovery-url must be provided.")
    if jwks_file:
        keys = load_jwks_file(jwks_file)
    else:
        if not kube_ca_file:
            raise RuntimeError("kube_ca_file is required when fetching JWKS from URL")
        if not jwks_url:
            discovery = vault_request("GET", discovery_url, token="", ca_file=kube_ca_file)
            jwks_url = discovery.get("jwks_uri")
            if not jwks_url:
                raise RuntimeError("OIDC discovery did not return jwks_uri.")
        keys = fetch_jwks_from_url(jwks_url, kube_ca_file)
    pem = jwks_to_pem(keys)
    payload = {
        "jwt_validation_pubkeys": [pem],
        "jwt_supported_algs": ["RS256"],
    }
    vault_request("POST", build_url(vault_url, f"v1/auth/{mount}/config"), token, payload=payload, ca_file=ca_file)


def write_jwt_role(vault_url, token, ca_file, mount, role_name, audience, policy_name, issuer):
    print(f"Writing JWT auth role '{role_name}'.")
    if isinstance(audience, str):
        audience = [item.strip() for item in audience.split(",") if item.strip()]
        if len(audience) == 1:
            audience = audience[0]
    payload = {
        "role_type": "jwt",
        "bound_audiences": audience,
        "user_claim": "sub",
        "policies": policy_name,
        "token_ttl": "1h",
    }
    if issuer:
        payload["bound_issuer"] = issuer
    vault_request("POST", build_url(vault_url, f"v1/auth/{mount}/role/{role_name}"), token, payload=payload, ca_file=ca_file)


def write_test_secret(vault_url, token, ca_file, secret_path, secret_key, secret_value):
    print(f"Writing test secret to '{secret_path}'.")
    if not secret_path.startswith("secret/data/"):
        raise ValueError("Test secret path must be a KV v2 path and start with 'secret/data/'.")
    payload = {"data": {secret_key: secret_value}}
    vault_request("POST", build_url(vault_url, f"v1/{secret_path}"), token, payload=payload, ca_file=ca_file)


def main():
    args = parse_args()
    
    write_policy(args.vault_url, args.vault_token, args.vault_ca_file, args.policy_name)
    
    enable_auth(args.vault_url, args.vault_token, args.vault_ca_file, "jwt", "jwt")
    configure_jwt(
        args.vault_url,
        args.vault_token,
        args.vault_ca_file,
        "jwt",
        args.jwt_discovery_url,
        args.jwt_jwks_url,
        args.jwt_jwks_file,
        args.jwt_client_id,
        None,
    )
    write_jwt_role(
        args.vault_url,
        args.vault_token,
        args.vault_ca_file,
        "jwt",
        args.jwt_role_name,
        args.jwt_audience,
        args.policy_name,
        args.kube_issuer,
    )
    ensure_kv_engine(args.vault_url, args.vault_token, args.vault_ca_file, mount="secret", version=2)
    write_test_secret(
        args.vault_url,
        args.vault_token,
        args.vault_ca_file,
        args.test_secret_path,
        args.test_secret_key,
        args.test_secret_value,
    )
    print("Vault JWT auth configuration complete.")
    print(f"JWT role: {args.jwt_role_name}")
    print(f"Test secret path: {args.test_secret_path}")


if __name__ == "__main__":
    main()
