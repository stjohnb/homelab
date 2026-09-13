#!/usr/bin/env bash
# Create the `claws` role and database on the shared PostgreSQL instance for the
# in-cluster claws-staging StatefulSet (#1274). Brand-new empty database: the data
# arrives from claws' own SQLite->Postgres import command (claws#2954), not here.
# The Secret holds only the password; apps/claws/statefulset-staging.yaml supplies
# the passwordless CLAWS_DATABASE_URL, the same shape as forgejo-db-secret.
set -euo pipefail

NS="default"
SECRET_NAME="claws-db-secret"

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

# Alphanumeric only: interpolated into a psql SQL literal, and consumed by claws
# as a URI password, so it needs no escaping in either (0024 rationale).
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
  if [ "$($P "select 1 from pg_roles where rolname='"'"'claws'"'"'")" = 1 ]; then
    $P "alter role claws with login password '"'"'$PW'"'"'"
  else
    $P "create role claws login password '"'"'$PW'"'"'"
  fi
  $P "select 1 from pg_database where datname='"'"'claws'"'"'" | grep -q 1 || \
    $P "create database claws owner claws"
  psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d claws -tAc \
    "grant all on schema public to claws"
'

kubectl create secret generic "$SECRET_NAME" -n "$NS" \
  --from-literal=password="$PASS"

echo "Created $SECRET_NAME and provisioned database claws"
