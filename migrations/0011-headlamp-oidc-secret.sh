#!/usr/bin/env bash
set -euo pipefail

SRC_SECRET="authentik-secrets"
DST_SECRET="headlamp-oidc"
NS="default"

CLIENT_SECRET_B64=$(kubectl get secret "$SRC_SECRET" -n "$NS" \
  -o jsonpath='{.data.HEADLAMP_OIDC_CLIENT_SECRET}' 2>/dev/null || true)
if [ -z "$CLIENT_SECRET_B64" ]; then
  echo "ERROR: HEADLAMP_OIDC_CLIENT_SECRET not found in $SRC_SECRET — run 0004-oidc-client-secrets.sh first" >&2
  exit 1
fi

CLIENT_ID_B64=$(printf '%s' "headlamp" | base64 | tr -d '\n')
ISSUER_URL_B64=$(printf '%s' "https://auth.home.bstjohn.net/application/o/headlamp/" | base64 | tr -d '\n')
SCOPES_B64=$(printf '%s' "openid profile email groups" | base64 | tr -d '\n')

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${DST_SECRET}
  namespace: ${NS}
type: Opaque
data:
  OIDC_CLIENT_ID: ${CLIENT_ID_B64}
  OIDC_CLIENT_SECRET: ${CLIENT_SECRET_B64}
  OIDC_ISSUER_URL: ${ISSUER_URL_B64}
  OIDC_SCOPES: ${SCOPES_B64}
EOF

echo "Wrote ${DST_SECRET} (4 keys)"
