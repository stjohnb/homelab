#!/usr/bin/env bash
# Mint the Seerr and Overseerr API keys into Secret `request-app-apikeys`.
# Seerr's oidc-init and Overseerr's apikey-init initContainers pin them into
# each app's settings.json `main.apiKey` before start, and the Sonarr/Radarr
# reconciler sidecars read them to poll approved requests (docs/servarr.md).
set -euo pipefail

SECRET_NAME="request-app-apikeys"
NS="default"

if kubectl get secret "$SECRET_NAME" -n "$NS" >/dev/null 2>&1; then
  echo "Secret $SECRET_NAME already exists, skipping"
  exit 0
fi

# 48 random alphanumeric chars ≈ 285 bits of entropy each. Suppress SIGPIPE from head.
SEERR_KEY=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48 || true)
if [ "${#SEERR_KEY}" -ne 48 ]; then
  echo "ERROR: generated seerr key is ${#SEERR_KEY} chars, expected 48" >&2
  exit 1
fi
OVERSEERR_KEY=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48 || true)
if [ "${#OVERSEERR_KEY}" -ne 48 ]; then
  echo "ERROR: generated overseerr key is ${#OVERSEERR_KEY} chars, expected 48" >&2
  exit 1
fi

kubectl create secret generic "$SECRET_NAME" -n "$NS" \
  --from-literal=seerr-api-key="$SEERR_KEY" \
  --from-literal=overseerr-api-key="$OVERSEERR_KEY"

echo "Created $SECRET_NAME"
