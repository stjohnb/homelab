#!/usr/bin/env bash
set -euo pipefail

# Generates every Authentik OIDC client secret in one pass. Replaces the 11
# byte-identical per-key scripts 0004/0005/0008/0009/0010/0013/0015/0016/0018/
# 0021/0022 (issue #859).
#
# Numbered 0004 (not 0023) deliberately: run-migrations.sh executes scripts in
# lexicographic order, and 0011-headlamp-oidc-secret.sh and
# 0019-forgejo-oidc-auth-source.sh both READ keys generated here. A higher
# number would make them fail on first run of a rebuilt cluster.
#
# To add a new OIDC service: append its key to KEYS below. Do NOT add a new
# per-key migration script.

SECRET_NAME="authentik-secrets"
NS="default"

KEYS=(
  MEALIE_OIDC_CLIENT_SECRET
  OPEN_WEBUI_OIDC_CLIENT_SECRET
  JELLYFIN_OIDC_CLIENT_SECRET
  JELLYSEERR_OIDC_CLIENT_SECRET
  HEADLAMP_OIDC_CLIENT_SECRET
  PROXMOX_OIDC_CLIENT_SECRET
  BIN_SCRAPER_OIDC_CLIENT_SECRET
  CLAWS_OIDC_CLIENT_SECRET
  FORGEJO_OIDC_CLIENT_SECRET
  SEERR_OIDC_CLIENT_SECRET
  HOME_ASSISTANT_OIDC_CLIENT_SECRET
)

# Ensure secret exists
kubectl get secret "$SECRET_NAME" -n "$NS" >/dev/null 2>&1 || \
  kubectl create secret generic "$SECRET_NAME" -n "$NS" >/dev/null 2>&1 || \
  echo "WARNING: create failed (may already exist), continuing"

ensure_key() {
  local key="$1" existing secret encoded

  # Bracket notation: JSONPath dot notation is unreliable for keys with
  # underscores/hyphens (same reason run-migrations.sh uses it).
  existing=$(kubectl get secret "$SECRET_NAME" -n "$NS" \
    -o jsonpath="{.data['${key}']}" 2>/dev/null || true)
  if [ -n "$existing" ]; then
    echo "Key $key already exists, skipping"
    return 0
  fi

  # `|| true` suppresses SIGPIPE (exit 141) from `tr` after `head` closes the
  # pipe; the 48 bytes already captured by `head` are still assigned.
  secret=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 48 || true)
  if [ "${#secret}" -ne 48 ]; then
    echo "ERROR: generated value for $key is ${#secret} chars, expected 48" >&2
    return 1
  fi

  encoded=$(printf '%s' "$secret" | base64 | tr -d '\n')
  if ! kubectl patch secret "$SECRET_NAME" -n "$NS" \
      --type=merge -p="{\"data\":{\"${key}\":\"${encoded}\"}}"; then
    echo "ERROR: failed to patch $key" >&2
    return 1
  fi
  echo "Successfully added $key"
}

FAILED=0
for key in "${KEYS[@]}"; do
  # `if !` disables errexit inside ensure_key, so one bad key does not abort
  # the loop and leave the rest ungenerated.
  if ! ensure_key "$key"; then
    FAILED=$((FAILED + 1))
  fi
done

if [ "$FAILED" -gt 0 ]; then
  echo "ERROR: ${FAILED} of ${#KEYS[@]} key(s) failed — will retry on next run" >&2
  exit 1
fi
echo "All ${#KEYS[@]} OIDC client secrets present"
