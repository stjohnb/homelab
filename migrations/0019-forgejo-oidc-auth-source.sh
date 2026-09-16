#!/usr/bin/env bash
set -euo pipefail

NS="default"
SOURCE_NAME="authentik"

POD=$(kubectl get pod -n "$NS" -l app=forgejo \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')
if [ -z "$POD" ]; then
  echo "No forgejo pod found, will retry on next migration run"
  exit 1
fi

# Idempotency: auth sources live in Forgejo's DB, not in Git.
if kubectl exec -n "$NS" "$POD" -- forgejo admin auth list \
     | awk 'NR>1 {print $2}' | grep -qx "$SOURCE_NAME"; then
  echo "Auth source $SOURCE_NAME already exists, skipping"
  exit 0
fi

CLIENT_SECRET=$(kubectl get secret authentik-secrets -n "$NS" \
  -o jsonpath='{.data.FORGEJO_OIDC_CLIENT_SECRET}' | base64 -d)
if [ -z "$CLIENT_SECRET" ]; then
  echo "FORGEJO_OIDC_CLIENT_SECRET not present yet, will retry on next run"
  exit 1
fi

# Feed the client secret over stdin, never as an argv: kubectl exec encodes each
# argument as a `command=` query parameter on the apiserver request URI, which
# lands verbatim in audit-log entries at any audit level. (#902)
printf '%s\n' "$CLIENT_SECRET" | kubectl exec -i -n "$NS" "$POD" -- sh -c '
  IFS= read -r S
  [ -n "$S" ] || { echo "ERROR: no client secret on stdin" >&2; exit 1; }
  exec forgejo admin auth add-oauth \
    --name "$1" \
    --provider openidConnect \
    --key forgejo \
    --secret "$S" \
    --auto-discover-url https://auth.home.bstjohn.net/application/o/forgejo/.well-known/openid-configuration \
    --scopes openid --scopes profile --scopes email --scopes groups \
    --group-claim-name groups \
    --admin-group infra
' _ "$SOURCE_NAME"

# The running server registers goth providers at startup, so a source added by
# a separate CLI process is not served until the pod restarts.
kubectl rollout restart deployment/forgejo -n "$NS"
kubectl rollout status deployment/forgejo -n "$NS" --timeout=120s || \
  echo "WARNING: rollout still in progress; source is already in the DB"
echo "Successfully added Forgejo OAuth2 source $SOURCE_NAME"
