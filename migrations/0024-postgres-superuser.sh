#!/usr/bin/env bash
set -euo pipefail

SECRET_NAME="postgres-superuser"
NS="default"

if kubectl get secret "$SECRET_NAME" -n "$NS" >/dev/null 2>&1; then
  echo "Secret $SECRET_NAME already exists, skipping"
  exit 0
fi

# 48 random alphanumeric chars ≈ 285 bits of entropy. Suppress SIGPIPE from head.
# Alphanumeric only: later migrations interpolate this value into SQL string
# literals when creating per-app roles, so it must not contain a quote or backslash.
PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48 || true)
if [ "${#PASS}" -ne 48 ]; then
  echo "ERROR: generated value for POSTGRES_PASSWORD is ${#PASS} chars, expected 48" >&2
  exit 1
fi

kubectl create secret generic "$SECRET_NAME" -n "$NS" \
  --from-literal=POSTGRES_PASSWORD="$PASS"

echo "Created $SECRET_NAME"
