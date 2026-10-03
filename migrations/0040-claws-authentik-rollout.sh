#!/usr/bin/env bash
# Restart the claws StatefulSet once the Authentik app passwords for the Claws
# service accounts (claws-reader / claws-admin) exist in authentik-secrets, so
# the pod picks up CLAWS_AUTHENTIK_{READER,ADMIN}_PASSWORD.
#
# 0004 generates CLAWS_READER_APP_PASSWORD and CLAWS_ADMIN_APP_PASSWORD. The
# claws Flux Kustomization depends only on claws-prepull, not on migrations,
# so the pod can start before the keys exist and would otherwise keep running
# without them (the refs are optional) until the next image bump.
#
# Never prints or decodes the values; it only checks that they are non-empty.
set -euo pipefail

NS="default"
SECRET_NAME="authentik-secrets"

ensure_claws_rollout() {
  STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"spec":{"template":{"metadata":{"annotations":{"migrations.fleet-infra.bstjohn.net/0040-claws-authentik-rollout":"%s"}}}}}\n' "$STAMP" | \
    kubectl patch statefulset claws -n "$NS" --type=merge --patch-file=/dev/stdin
}

for key in CLAWS_READER_APP_PASSWORD CLAWS_ADMIN_APP_PASSWORD; do
  # Bracket notation: JSONPath dot notation is unreliable for keys with
  # underscores (same reason 0004 uses it).
  existing=$(kubectl get secret "$SECRET_NAME" -n "$NS" \
    -o jsonpath="{.data['${key}']}" 2>/dev/null || true)
  if [ -z "$existing" ]; then
    echo "Key $key missing from $SECRET_NAME, will retry after 0004 has generated it"
    exit 1
  fi
done

ensure_claws_rollout
echo "Claws Authentik app passwords present, triggered claws rollout"
