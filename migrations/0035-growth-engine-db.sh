#!/usr/bin/env bash
# Create the `growth_engine` role and database on the shared PostgreSQL instance
# for St-John-Software/growth-engine (Forgejo, #1368). Brand-new empty database:
# growth-engine#4 owns the schema and runs its own migrations from a single
# DATABASE_URL, not this script. The Secret holds only the password; a later
# Deployment supplies a passwordless DATABASE_URL, the same shape as
# claws-db-secret. The password is alphanumeric only: it is interpolated into a
# SQL string literal and later consumed as a URI password, so it needs no
# escaping in either (0024 rationale).
set -euo pipefail

NS="default"
SECRET_NAME="growth-engine-db-secret"

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
  if [ "$($P "select 1 from pg_roles where rolname='"'"'growth_engine'"'"'")" = 1 ]; then
    $P "alter role growth_engine with login password '"'"'$PW'"'"'"
  else
    $P "create role growth_engine login password '"'"'$PW'"'"'"
  fi
  $P "select 1 from pg_database where datname='"'"'growth_engine'"'"'" | grep -q 1 || \
    $P "create database growth_engine owner growth_engine"
  psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d growth_engine -tAc \
    "grant all on schema public to growth_engine"
'

kubectl create secret generic "$SECRET_NAME" -n "$NS" \
  --from-literal=password="$PASS"

echo "Created $SECRET_NAME and provisioned database growth_engine"
