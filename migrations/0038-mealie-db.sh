#!/usr/bin/env bash
# Create the `mealie` role and database on the shared PostgreSQL instance for
# St-John-Software/fleet-infra (Mealie SQLite -> Postgres cutover). Mealie's own
# admin backup/restore (AlchemyExporter.restore, also used for the SQLite copy)
# issues `SET session_replication_role = 'replica'` to disable FK checks while
# loading rows, which is normally a superuser-only parameter. On Postgres 15+
# `GRANT SET ON PARAMETER` lets the plain owner role do that itself, so `mealie`
# is never made a superuser (contrast `immich`, which is one for its own
# extension-management reasons — see docs/postgres.md). `pg_trgm`, which Mealie
# creates at startup, is a trusted extension, so the database owner can create it.
# This script only provisions an empty database: Mealie keeps running on SQLite
# until a later migration copies its data in and the Deployment is cut over, so
# it makes no row-count assertion (unlike 0025/0026).
set -euo pipefail

NS="default"
SECRET_NAME="mealie-db-secret"

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
  if [ "$($P "select 1 from pg_roles where rolname='"'"'mealie'"'"'")" = 1 ]; then
    $P "alter role mealie with login password '"'"'$PW'"'"'"
  else
    $P "create role mealie login password '"'"'$PW'"'"'"
  fi
  $P "select 1 from pg_database where datname='"'"'mealie'"'"'" | grep -q 1 || \
    $P "create database mealie owner mealie"
  psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d mealie -tAc \
    "grant all on schema public to mealie"
  psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d postgres -tAc \
    "grant set on parameter session_replication_role to mealie"
'

kubectl create secret generic "$SECRET_NAME" -n "$NS" \
  --from-literal=password="$PASS"

echo "Created $SECRET_NAME and provisioned database mealie"
