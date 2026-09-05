#!/usr/bin/env bash
set -euo pipefail

NS="default"
SECRET_NAME="headlamp-oidc"

# Skip if already rekeyed (uppercase key present)
if kubectl get secret "$SECRET_NAME" -n "$NS" \
     -o jsonpath='{.data.OIDC_CLIENT_ID}' 2>/dev/null | grep -q .; then
  echo "headlamp-oidc already has uppercase keys — skipping"
  exit 0
fi

# Fail loudly if secret missing (means 0011 hasn't run — order is enforced numerically)
if ! kubectl get secret "$SECRET_NAME" -n "$NS" >/dev/null 2>&1; then
  echo "ERROR: $SECRET_NAME not found — 0011 must run first" >&2
  exit 1
fi

# Read the four existing values as raw base64 strings (do NOT decode/re-encode)
CID=$(kubectl get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{.data.clientID}')
CSEC=$(kubectl get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{.data.clientSecret}')
ISS=$(kubectl get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{.data.issuerURL}')
SCP=$(kubectl get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{.data.scopes}')

if [ -z "$CID" ] || [ -z "$CSEC" ] || [ -z "$ISS" ] || [ -z "$SCP" ]; then
  echo "ERROR: one of clientID/clientSecret/issuerURL/scopes missing in $SECRET_NAME" >&2
  exit 1
fi

# Merge-patch: add uppercase keys, remove old lowercase keys (null deletes a key)
kubectl patch secret "$SECRET_NAME" -n "$NS" --type=merge -p "$(cat <<EOF
{
  "data": {
    "OIDC_CLIENT_ID": "${CID}",
    "OIDC_CLIENT_SECRET": "${CSEC}",
    "OIDC_ISSUER_URL": "${ISS}",
    "OIDC_SCOPES": "${SCP}",
    "clientID": null,
    "clientSecret": null,
    "issuerURL": null,
    "scopes": null
  }
}
EOF
)"

# Restart so pod picks up the new env vars (envFrom doesn't auto-reload)
kubectl rollout restart deployment/headlamp -n "$NS"

echo "Rekeyed ${SECRET_NAME} and restarted headlamp deployment"
