#!/usr/bin/env bash
set -euo pipefail

KEY="PG_PASS"
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

# Try to extract the current password from the running PostgreSQL pod
# to avoid generating a new password that mismatches the database
SECRET=""
# Historical branch: the `authentik-postgresql` Deployment was removed in #996
# when Authentik moved to the shared `apps/postgres` instance, so no pod carries
# this label any more. On an existing cluster PG_PASS is already set and this
# script short-circuits above; on a fresh cluster the lookup finds nothing and
# the generate path below runs, which is the intended behaviour.
PG_POD=$(kubectl get pod -n "$NS" -l app=authentik-postgresql \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$PG_POD" ]; then
  SECRET=$(kubectl exec -n "$NS" "$PG_POD" -- \
    printenv POSTGRES_PASSWORD 2>/dev/null || true)
fi

if [ -z "$SECRET" ]; then
  echo "No running PostgreSQL pod found, generating new password"
  # `|| true` suppresses SIGPIPE (exit 141) from `tr` after `head` closes the pipe;
  # the 64 bytes already captured by `head` are still assigned to SECRET.
  SECRET=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 64 || true)
  if [ "${#SECRET}" -ne 64 ]; then
    echo "ERROR: generated value for $KEY is ${#SECRET} chars, expected 64" >&2
    exit 1
  fi
else
  echo "Extracted existing password from running PostgreSQL pod"
fi

ENCODED=$(printf '%s' "$SECRET" | base64 | tr -d '\n')
kubectl patch secret "$SECRET_NAME" -n "$NS" \
  --type=merge \
  -p="{\"data\":{\"$KEY\":\"$ENCODED\"}}"
echo "Successfully added $KEY"
