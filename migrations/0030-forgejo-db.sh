#!/usr/bin/env bash
# Create the `forgejo` role/database on the shared PostgreSQL instance and copy
# Forgejo's embedded SQLite database into it (#1216). One-shot: the cutover of
# apps/forgejo/deployment.yaml to DB_TYPE=postgres lands in a separate PR, so
# anything written to SQLite between this migration and that rollout is lost.
# Same shape and same caveat as 0025-authentik-db.sh.
#
# The dump is taken from the live server: `forgejo dump` only exists inside the
# running container, so there is no scale-to-0 variant of this step. A write
# landing mid-dump can therefore produce referential skew the row-count
# assertions below cannot see. Accepted: this is a single-user forge, and the
# cutover PR already declares everything written after this point lost.
set -euo pipefail

NS="default"
SECRET_NAME="forgejo-db-secret"

if kubectl get secret "$SECRET_NAME" -n "$NS" >/dev/null 2>&1; then
  echo "Secret $SECRET_NAME already exists, skipping"
  exit 0
fi

PG_POD=$(kubectl get pod -n "$NS" -l app=postgres \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$PG_POD" ]; then
  echo "No running postgres pod yet, will retry on next migration run"; exit 1
fi

FJ_POD=$(kubectl get pod -n "$NS" -l app=forgejo \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$FJ_POD" ]; then
  echo "No running forgejo pod yet, will retry on next migration run"; exit 1
fi

# Alphanumeric only: interpolated into a psql SQL literal (0024 rationale).
PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48 || true)
if [ "${#PASS}" -ne 48 ]; then
  echo "ERROR: password generation failed (${#PASS} chars, expected 48)" >&2; exit 1
fi

# Role + empty database. Password on stdin, never in argv (#902).
printf '%s\n' "$PASS" | kubectl exec -i -n "$NS" "$PG_POD" -- sh -c '
  set -eu
  IFS= read -r PW
  [ -n "$PW" ] || { echo "no password on stdin" >&2; exit 1; }
  export PGPASSWORD="$POSTGRES_PASSWORD"
  P="psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U $POSTGRES_USER -tAc"
  if [ "$($P "select 1 from pg_roles where rolname='"'"'forgejo'"'"'")" = 1 ]; then
    $P "alter role forgejo with login password '"'"'$PW'"'"'"
  else
    $P "create role forgejo login password '"'"'$PW'"'"'"
  fi
  $P "select 1 from pg_database where datname='"'"'forgejo'"'"'" | grep -q 1 || \
    $P "create database forgejo owner forgejo"
  psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d forgejo -tAc \
    "grant all on schema public to forgejo"
'

# Dump the live SQLite DB in Postgres dialect and stream forgejo-db.sql straight
# into the postgres pod. `forgejo dump` rewrites --file to end in the --type
# suffix, so dump into an empty dir and take whatever appears (same trap as
# apps/forgejo/cronjob-backup.yaml). All dump chatter goes to /dev/null so only
# the SQL reaches the pipe. Repos/LFS/attachments/packages/index/logs are
# skipped: this migration only moves the database.
kubectl exec -n "$NS" "$FJ_POD" -- sh -c '
  set -eu
  rm -rf /tmp/dbdump && mkdir -p /tmp/dbdump
  forgejo dump --database postgres --type tar.gz --quiet \
    --file /tmp/dbdump/d.tar.gz --tempdir /tmp/dbdump \
    --skip-repository --skip-custom-dir --skip-lfs-data --skip-attachment-data \
    --skip-package-data --skip-index --skip-log >/dev/null 2>&1
  F=$(find /tmp/dbdump -maxdepth 1 -type f -name "d*" | head -n 1)
  [ -n "$F" ] || { echo "forgejo dump produced no file" >&2; exit 1; }
  tar -xzOf "$F" forgejo-db.sql
  rm -rf /tmp/dbdump
' | kubectl exec -i -n "$NS" "$PG_POD" -- sh -c 'cat > /tmp/forgejo-db.sql'

# Load the schema as the forgejo role so every object is owned by it, the rows
# as the superuser (see below), then repair the serial sequences. xorm's dump emits CREATE TABLE ... SERIAL plus INSERTs with
# explicit ids and never advances the sequences, so without this every first
# write after cutover fails with "duplicate key value violates unique
# constraint" (go-gitea#740, go-gitea#5472).
#
# Everything from the load onwards runs under `fail`, which drops the database
# before exiting. Without it a mid-file `psql -f` abort or a failed sequence
# repair would leave a half-populated `forgejo` database that the `select 1 from
# pg_database` guard above happily skips re-creating, so every later retry would
# replay the same SQL into it and fail identically until a human dropped it by
# hand.
printf '%s\n' "$PASS" | kubectl exec -i -n "$NS" "$PG_POD" -- sh -c '
  set -eu
  IFS= read -r PW
  [ -n "$PW" ] || { echo "no password on stdin" >&2; exit 1; }
  SZ=$(wc -c < /tmp/forgejo-db.sql)
  [ "$SZ" -gt 20480 ] || { echo "forgejo-db.sql is only $SZ bytes" >&2; exit 1; }
  fail() {
    echo "$1; dropping database so a retry starts clean" >&2
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" \
      -d postgres -c "drop database forgejo with (force)" || true
    exit 1
  }
  # xorm writes one statement per line, and writes the tables in an order that
  # ignores their foreign keys: access_token_resource_repo, collaboration,
  # access, action_user, action_runner_token, forgejo_auth_token and
  # pull_request all REFERENCE repository / "user" / access_token / issue,
  # which appear later in the file, so a straight `psql -f` stops at the first
  # `relation "public.repository" does not exist` (first run, 2026-09-09).
  # Load it in three parts instead: the CREATE TABLE lines in passes (they are
  # IF NOT EXISTS, so a second pass only creates what the first could not),
  # then the indexes, then the rows as the superuser under
  # session_replication_role=replica so row order does not matter either.
  # Ownership is unaffected: the tables are created as forgejo; inserts do not
  # change ownership.
  OTHER=$(grep -v -E "^(INSERT INTO|CREATE TABLE|CREATE (UNIQUE )?INDEX|SELECT setval|/\*|$)" /tmp/forgejo-db.sql | wc -l)
  [ "$OTHER" -eq 0 ] || fail "forgejo-db.sql has $OTHER lines of an unexpected shape (multi-line statements?)"
  grep "^CREATE TABLE" /tmp/forgejo-db.sql > /tmp/forgejo-ddl.sql
  grep -E "^CREATE (UNIQUE )?INDEX" /tmp/forgejo-db.sql > /tmp/forgejo-idx.sql
  grep -v -E "^CREATE (TABLE|(UNIQUE )?INDEX)" /tmp/forgejo-db.sql > /tmp/forgejo-dml.sql
  export PGPASSWORD="$PW"
  for pass in 1 2 3; do
    psql -h 127.0.0.1 -U forgejo -d forgejo -q -f /tmp/forgejo-ddl.sql >/dev/null 2>&1 || true
  done
  psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U forgejo -d forgejo -q -f /tmp/forgejo-ddl.sql >/dev/null \
    || fail "creating tables failed after 3 passes"
  psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U forgejo -d forgejo -q -f /tmp/forgejo-idx.sql >/dev/null \
    || fail "creating indexes failed"
  { echo "SET session_replication_role = replica;"; cat /tmp/forgejo-dml.sql; } | \
    PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" \
      -d forgejo -q -o /dev/null \
    || fail "loading rows failed"
  rm -f /tmp/forgejo-db.sql /tmp/forgejo-ddl.sql /tmp/forgejo-idx.sql /tmp/forgejo-dml.sql
  psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U forgejo -d forgejo -q -c "
    DO \$\$
    DECLARE r record;
    BEGIN
      FOR r IN
        SELECT c.relname AS tbl, a.attname AS col
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0
        WHERE n.nspname = '"'"'public'"'"' AND c.relkind = '"'"'r'"'"'
          AND pg_get_serial_sequence('"'"'public.'"'"' || quote_ident(c.relname), a.attname) IS NOT NULL
      LOOP
        EXECUTE format(
          '"'"'SELECT setval(pg_get_serial_sequence(%L, %L), COALESCE((SELECT MAX(%I) FROM public.%I), 0) + 1, false)'"'"',
          '"'"'public.'"'"' || r.tbl, r.col, r.col, r.tbl);
      END LOOP;
    END\$\$;" || fail "serial sequence repair failed"
  Q="psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U forgejo -d forgejo -tAc"
  USERS=$($Q "select count(*) from \"user\"") || fail "counting user rows failed"
  REPOS=$($Q "select count(*) from repository") || fail "counting repository rows failed"
  SEQS=$($Q "select count(*) from pg_sequences where schemaname='"'"'public'"'"'") \
    || fail "counting sequences failed"
  echo "loaded: user=$USERS repository=$REPOS sequences=$SEQS"
  if [ "$USERS" -lt 1 ] || [ "$REPOS" -lt 1 ] || [ "$SEQS" -lt 20 ]; then
    fail "load verification failed (user=$USERS repository=$REPOS sequences=$SEQS)"
  fi
'

kubectl create secret generic "$SECRET_NAME" -n "$NS" --from-literal=password="$PASS"

echo "Provisioned database forgejo and copied the SQLite contents into it"
