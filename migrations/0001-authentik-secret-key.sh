#!/usr/bin/env bash
set -euo pipefail

KEY="AUTHENTIK_SECRET_KEY"
SECRET_NAME="authentik-secrets"
NS="default"

# Ensure secret exists
kubectl get secret "$SECRET_NAME" -n "$NS" >/dev/null 2>&1 || \
  kubectl create secret generic "$SECRET_NAME" -n "$NS" >/dev/null 2>&1 || \
  echo "WARNING: create failed (may already exist), continuing"

# Check if key already exists
EXISTING=$(kubectl get secret "$SECRET_NAME" -n "$NS" \
  -o jsonpath="{.data.$KEY}" 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
  echo "Key $KEY already exists, skipping"
  exit 0
fi

# Generate and apply
# `|| true` suppresses SIGPIPE (exit 141) from `tr` after `head` closes the pipe;
# the 100 bytes already captured by `head` are still assigned to SECRET.
SECRET=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 100 || true)
if [ "${#SECRET}" -ne 100 ]; then
  echo "ERROR: generated value for $KEY is ${#SECRET} chars, expected 100" >&2
  exit 1
fi
ENCODED=$(printf '%s' "$SECRET" | base64 | tr -d '\n')
kubectl patch secret "$SECRET_NAME" -n "$NS" \
  --type=merge \
  -p="{\"data\":{\"$KEY\":\"$ENCODED\"}}"
echo "Successfully added $KEY"
