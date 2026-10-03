#!/usr/bin/env bash
# Mint Garage's RPC secret and admin API token into Secret `garage-secrets`,
# read by apps/garage/deployment.yaml as GARAGE_RPC_SECRET / GARAGE_ADMIN_TOKEN.
set -euo pipefail

SECRET_NAME="garage-secrets"
NS="default"

if kubectl get secret "$SECRET_NAME" -n "$NS" >/dev/null 2>&1; then
  echo "Secret $SECRET_NAME already exists, skipping"
  exit 0
fi

# Garage requires rpc_secret to be exactly 32 bytes, hex-encoded (64 chars).
RPC_SECRET=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
if [ "${#RPC_SECRET}" -ne 64 ]; then
  echo "ERROR: generated rpc secret is ${#RPC_SECRET} chars, expected 64" >&2
  exit 1
fi

# 48 random alphanumeric chars ≈ 285 bits of entropy. Suppress SIGPIPE from head.
ADMIN_TOKEN=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48 || true)
if [ "${#ADMIN_TOKEN}" -ne 48 ]; then
  echo "ERROR: generated admin token is ${#ADMIN_TOKEN} chars, expected 48" >&2
  exit 1
fi

kubectl create secret generic "$SECRET_NAME" -n "$NS" \
  --from-literal=GARAGE_RPC_SECRET="$RPC_SECRET" \
  --from-literal=GARAGE_ADMIN_TOKEN="$ADMIN_TOKEN"

echo "Created $SECRET_NAME"
