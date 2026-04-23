SA_TOKEN=$(kubectl --context kind-vault-lab-eso -n external-secrets create token external-secrets)

VAULT_CLIENT_TOKEN=$(curl -sk -X POST https://localhost:32080/v1/auth/jwt/login \
  -H "Content-Type: application/json" \
  -d "{\"jwt\":\"$SA_TOKEN\",\"role\":\"external-secrets-jwt\"}" | jq -r '.auth.client_token')
  
curl -sk -H "X-Vault-Token: $VAULT_CLIENT_TOKEN" \
  https://localhost:32080/v1/secret/data/eso-test | jq .