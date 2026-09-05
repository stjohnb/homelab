#!/usr/bin/env bash
# Create the `garden` role and database on the shared PostgreSQL instance
# (#996) and write garden-db-secret with a DATABASE_URL for the app. Garden
# is a brand-new app with no prior database to copy from, unlike
# 0025-authentik-db.sh / 0026-immich-db.sh.
set -euo pipefail

NS="default"
SECRET_NAME="garden-db-secret"

if kubectl get secret "$SECRET_NAME" -n "$NS" >/dev/null 2>&1; then
  echo "Secret $SECRET_NAME already exists, skipping"
  exit 0
fi

POD=$(kubectl get pod -n "$NS" -l app=postgres \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$POD" ]; then
  echo "No running postgres pod yet, will retry on next migration run"
  exit 1
fi

# Alphanumeric only: interpolated into a psql SQL literal and into a
# DATABASE_URL URI, so it needs no escaping in either.
PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48 || true)
if [ "${#PASS}" -ne 48 ]; then
  echo "ERROR: password generation failed (${#PASS} chars, expected 48)" >&2
  exit 1
fi

# Password goes in over stdin, never as a kubectl exec argv — exec encodes every
# argument into the apiserver requestURI, which lands in audit logs (#902).
printf '%s\n' "$PASS" | kubectl exec -i -n "$NS" "$POD" -- sh -c '
  set -eu
  IFS= read -r PW
  [ -n "$PW" ] || { echo "no password on stdin" >&2; exit 1; }
  export PGPASSWORD="$POSTGRES_PASSWORD"
  P="psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U $POSTGRES_USER -tAc"
  if [ "$($P "select 1 from pg_roles where rolname='"'"'garden'"'"'")" = 1 ]; then
    $P "alter role garden with login password '"'"'$PW'"'"'"
  else
    $P "create role garden login password '"'"'$PW'"'"'"
  fi
  $P "select 1 from pg_database where datname='"'"'garden'"'"'" | grep -q 1 || \
    $P "create database garden owner garden"
  psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d garden -tAc \
    "grant all on schema public to garden"
'

kubectl create secret generic "$SECRET_NAME" -n "$NS" \
  --from-literal=DATABASE_URL="postgresql://garden:${PASS}@postgres.default.svc.cluster.local:5432/garden"

echo "Created $SECRET_NAME and provisioned database garden"
