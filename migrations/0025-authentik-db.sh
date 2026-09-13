#!/usr/bin/env bash
# Copy the Authentik database from the dedicated `authentik-postgresql` instance
# into the shared `apps/postgres` instance (#996). One-shot: the cutover of
# Authentik's DB host to `postgres` lands in a separate PR, so anything written
# to the old instance between this migration and that rollout is lost.
set -euo pipefail

NS="default"

APP_PW=$(kubectl get secret authentik-secrets -n "$NS" \
  -o jsonpath='{.data.PG_PASS}' 2>/dev/null | base64 -d || true)
if [ -z "$APP_PW" ]; then
  echo "ERROR: PG_PASS not present in authentik-secrets" >&2
  exit 1
fi

NEW_POD=$(kubectl get pod -n "$NS" -l app=postgres \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$NEW_POD" ]; then
  echo "No running postgres pod yet, will retry on next migration run"
  exit 1
fi

# Feed the app password over stdin, never as an argv: kubectl exec encodes each
# argument as a `command=` query parameter on the apiserver request URI, which
# lands verbatim in audit-log entries at any audit level. (#902)
#
# Inside the pod use TCP + password rather than the unix socket: the immich-app
# entrypoint rewrites postgresql.conf, so local `trust` cannot be assumed.
printf '%s\n' "$APP_PW" | kubectl exec -i -n "$NS" "$NEW_POD" -- sh -c '
  set -eu
  IFS= read -r APP_PW
  [ -n "$APP_PW" ] || { echo "no password on stdin" >&2; exit 1; }
  export PGPASSWORD="$POSTGRES_PASSWORD"
  P="psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U $POSTGRES_USER -tAc"
  if [ "$($P "select 1 from pg_roles where rolname='"'"'authentik'"'"'")" = 1 ]; then
    $P "alter role authentik with login password '"'"'$APP_PW'"'"'"
  else
    $P "create role authentik login password '"'"'$APP_PW'"'"'"
  fi
  $P "select 1 from pg_database where datname='"'"'authentik'"'"'" | grep -q 1 || \
    $P "create database authentik owner authentik"
  PGPASSWORD="$APP_PW" pg_dump -h authentik-postgresql -U authentik -d authentik -Fc -f /tmp/authentik.dump
  pg_restore -h 127.0.0.1 -U "$POSTGRES_USER" -d authentik --no-owner --role=authentik /tmp/authentik.dump
  rm -f /tmp/authentik.dump
  N=$(psql -h 127.0.0.1 -U "$POSTGRES_USER" -d authentik -tAc "select count(*) from authentik_core_user")
  echo "authentik_core_user rows: $N"
  [ "$N" -gt 0 ] || { psql -h 127.0.0.1 -U "$POSTGRES_USER" -d postgres -c "drop database authentik with (force)"; echo "restore verification failed" >&2; exit 1; }
'

echo "Copied the authentik database into the shared postgres instance"
