#!/usr/bin/env bash
# Copy the Immich database from the `immich-postgres` sidecar inside the Immich
# pod into the shared `apps/postgres` instance (#996). One-shot: the cutover of
# Immich's DB host to `postgres` lands in a separate PR, so anything written to
# the old instance between this migration and that rollout is lost.
#
# The dump source lives in the Immich pod, which is pinned to the storage node
# (k3s-nas). While the NAS is powered off there is nothing to dump, so this
# script exits non-zero and is retried on the next reconcile.
set -euo pipefail

NS="default"

APP_PW=$(kubectl get secret immich-db-secret -n "$NS" \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
if [ -z "$APP_PW" ]; then
  echo "ERROR: password not present in immich-db-secret" >&2
  exit 1
fi

IMMICH_POD=$(kubectl get pod -n "$NS" -l app=immich,component=server \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$IMMICH_POD" ]; then
  echo "immich pod not running (NAS asleep?), will retry on next migration run"
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
#
# The `immich` role is created SUPERUSER: Immich creates and updates extensions
# on version upgrades, and its built-in backup uses pg_dumpall. The `vectors`,
# `uuid-ossp`, `unaccent`, `cube`, `earthdistance` and `pg_trgm` extensions come
# out of the dump and restore under `SET ROLE immich` for the same reason.
printf '%s\n' "$APP_PW" | kubectl exec -i -n "$NS" "$NEW_POD" -- sh -c '
  set -eu
  IFS= read -r APP_PW
  [ -n "$APP_PW" ] || { echo "no password on stdin" >&2; exit 1; }
  export PGPASSWORD="$POSTGRES_PASSWORD"
  P="psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U $POSTGRES_USER -tAc"
  if [ "$($P "select 1 from pg_roles where rolname='"'"'immich'"'"'")" = 1 ]; then
    $P "alter role immich with login superuser password '"'"'$APP_PW'"'"'"
  else
    $P "create role immich login superuser password '"'"'$APP_PW'"'"'"
  fi
  $P "select 1 from pg_database where datname='"'"'immich'"'"'" | grep -q 1 || \
    $P "create database immich owner immich"
  PGPASSWORD="$APP_PW" pg_dump -h immich-postgres -U immich -d immich -Fc -f /tmp/immich.dump
  pg_restore -h 127.0.0.1 -U "$POSTGRES_USER" -d immich --no-owner --role=immich /tmp/immich.dump
  rm -f /tmp/immich.dump
  ASSETS=$(psql -h 127.0.0.1 -U "$POSTGRES_USER" -d immich -tAc "select count(*) from asset")
  USERS=$(psql -h 127.0.0.1 -U "$POSTGRES_USER" -d immich -tAc "select count(*) from \"user\"")
  echo "asset rows: $ASSETS, user rows: $USERS"
  if [ "$ASSETS" -le 0 ] || [ "$USERS" -le 0 ]; then
    psql -h 127.0.0.1 -U "$POSTGRES_USER" -d postgres -c "drop database immich with (force)"
    echo "restore verification failed" >&2
    exit 1
  fi
'

echo "Copied the immich database into the shared postgres instance"
