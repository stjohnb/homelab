#!/usr/bin/env bash
set -euo pipefail

SECRET_NAME="bin-scraper-session"
NS="default"

if kubectl get secret "$SECRET_NAME" -n "$NS" >/dev/null 2>&1; then
  echo "Secret $SECRET_NAME already exists, skipping"
  exit 0
fi

# 64 random alphanumeric chars ≈ 380 bits of entropy. Suppress SIGPIPE from head.
SECRET=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64 || true)
if [ "${#SECRET}" -ne 64 ]; then
  echo "ERROR: generated value for session-secret is ${#SECRET} chars, expected 64" >&2
  exit 1
fi

kubectl create secret generic "$SECRET_NAME" -n "$NS" \
  --from-literal=session-secret="$SECRET"

echo "Created $SECRET_NAME"
