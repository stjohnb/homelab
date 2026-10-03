#!/usr/bin/env bash
set -euo pipefail

NS="default"
SECRET_NAME="renovate-forgejo-token"

# Idempotency guard — see #923: the `get` grant in migrations/rbac.yaml is
# load-bearing, or this reports "missing" forever and re-runs `create`.
if kubectl get secret "$SECRET_NAME" -n "$NS" >/dev/null 2>&1; then
  echo "Secret $SECRET_NAME already exists, skipping"
  exit 0
fi

POD=$(kubectl get pod -n "$NS" -l app=forgejo \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')
if [ -z "$POD" ]; then
  echo "No forgejo pod found, will retry on next migration run"
  exit 1
fi

# The bot is a site admin because a migration has no pre-existing admin
# credential with which to add a non-admin user to the org and grant it write
# on each repo — and "add the next repo to a list" is the acceptance criterion.
# The blast radius is bounded by TOKEN SCOPES, not by the account: no
# write:admin / read:admin scope is granted, so this token cannot reach any
# Forgejo admin API. Create and token-mint happen inside one in-pod shell so
# the token never becomes a kubectl exec argv (#902).
TOKEN=$(kubectl exec -n "$NS" "$POD" -- sh -c '
  forgejo admin user create \
    --username renovate \
    --fullname "Renovate Bot" \
    --email renovate@home.bstjohn.net \
    --admin \
    --random-password --random-password-length 32 \
    --must-change-password=false >/dev/null 2>&1 || true
  forgejo admin user generate-access-token \
    --username renovate \
    --token-name renovate-k8s \
    --scopes write:repository,write:issue,read:user,read:organization \
    --raw
' | tr -d '[:space:]')

if [ -z "$TOKEN" ]; then
  echo "ERROR: generate-access-token returned nothing" >&2
  exit 1
fi

kubectl create secret generic "$SECRET_NAME" -n "$NS" --from-literal=token="$TOKEN"
echo "Created $SECRET_NAME for the Forgejo renovate bot user"
