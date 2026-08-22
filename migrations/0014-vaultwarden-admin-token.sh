#!/usr/bin/env bash
set -euo pipefail

SECRET_NAME="vaultwarden-admin"
NS="default"

if kubectl get secret "$SECRET_NAME" -n "$NS" >/dev/null 2>&1; then
  echo "Secret $SECRET_NAME already exists, skipping"
  exit 0
fi

# 64 random alphanumeric chars ≈ 380 bits of entropy. Suppress SIGPIPE from head.
TOKEN=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64 || true)
if [ "${#TOKEN}" -ne 64 ]; then
  echo "ERROR: generated value for admin_token is ${#TOKEN} chars, expected 64" >&2
  exit 1
fi

kubectl create secret generic "$SECRET_NAME" -n "$NS" \
  --from-literal=admin_token="$TOKEN"

echo "Created $SECRET_NAME"
