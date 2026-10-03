#!/usr/bin/env bash
# Copy Mealie's SQLite database (/app/data/mealie.db on the mealie-data PVC) into
# the `mealie` database on the shared PostgreSQL instance provisioned by
# 0038-mealie-db.sh. One-shot: the cutover of apps/mealie/deployment.yaml to
# DB_ENGINE=postgres lands in a separate PR, so anything written to SQLite
# between this migration and that rollout is lost. Same caveat as 0026/0030.
#
# The copy runs inside the live v2.6.0 Mealie pod with Mealie's own
# AlchemyExporter (the engine behind its admin backup/restore): dump() from the
# SQLite file, restore() into Postgres. restore() runs alembic and init_db.main(),
# which both take the database URL from get_app_settings().DB_URL — i.e. from
# env, not from the URL handed to the exporter — so the Python process is started
# with DB_ENGINE=postgres and the POSTGRES_* vars, and only the SQLite source is
# given an explicit URL. restore() deletes and reloads every table it writes, and
# any tables already present are dropped first, so a retry after a partial run is
# safe *only* while the pod is still on SQLite — see the DB_ENGINE guard below.
# restore() silently drops rows that fail foreign-key checks (clean_rows), so
# every table's row count is compared against the dump taken before restore()
# (restore() mutates dump in place), and a hard mismatch on users/groups/recipes
# fails the migration; other tables are reported but don't fail the run, since
# SQLite's lack of FK enforcement means old orphaned rows are plausible there.
#
# Once the cutover PR flips apps/mealie/deployment.yaml to DB_ENGINE=postgres,
# a retry of this migration (e.g. after an earlier failed run) would otherwise
# run inside a pod already serving from Postgres, drop every live table via
# drop_all(), and reload the stale SQLite snapshot still sitting on the PVC.
# The guard below refuses to run once the pod's own DB_ENGINE is no longer
# sqlite, so that failure mode requires the pod to already be misconfigured
# rather than relying on merge order between this PR and the cutover.
set -euo pipefail

NS="default"

PW=$(kubectl get secret mealie-db-secret -n "$NS" \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
if [ -z "$PW" ]; then
  echo "ERROR: password not present in mealie-db-secret" >&2
  exit 1
fi

POD=$(kubectl get pod -n "$NS" -l app=mealie \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$POD" ]; then
  echo "No running mealie pod yet, will retry on next migration run"
  exit 1
fi

# Password goes in over stdin as the first line, never as a kubectl exec argv —
# exec encodes every argument into the apiserver requestURI, which lands in
# audit logs (#902). `sh` consumes line 1, then `python -` reads the rest of
# stdin as its program.
{
  printf '%s\n' "$PW"
  cat <<'PY'
import sys

from sqlalchemy import inspect, text

from mealie.core.config import get_app_settings
from mealie.services.backups_v2.alchemy_exporter import AlchemyExporter

SQLITE_PATH = "/app/data/mealie.db"
STRICT_TABLES = ("users", "groups", "recipes")

src = AlchemyExporter(f"sqlite:///{SQLITE_PATH}")
dst = AlchemyExporter(get_app_settings().DB_URL)
assert dst.engine.dialect.name == "postgresql", f"destination is {dst.engine.dialect.name}, not postgresql"

dump = src.dump()
# restore() mutates dump in place, so the expected counts have to come from
# the dump taken here, not a second read of the SQLite file afterwards.
expected = {t: len(rows) for t, rows in dump.items() if t != "alembic_version"}

# drop_all() ends with DROP TYPE authmethod, which fails on an empty database.
if inspect(dst.engine).get_table_names():
    print("mealie postgres database not empty, dropping existing tables before restore")
    dst.drop_all()

dst.restore(dump)

with dst.engine.connect() as conn:
    actual = {t: conn.execute(text(f"select count(*) from {t}")).scalar() for t in expected}

mismatched = []
for t in sorted(expected):
    print(f"{t}: dump={expected[t]} postgres={actual[t]}")
    if expected[t] != actual[t]:
        mismatched.append(t)

if mismatched:
    print(f"row count mismatch in: {', '.join(mismatched)}", file=sys.stderr)

if any(t in STRICT_TABLES for t in mismatched) or expected.get("recipes", 0) == 0:
    print("restore verification failed", file=sys.stderr)
    sys.exit(1)
PY
} | kubectl exec -i -n "$NS" "$POD" -- sh -c 'IFS= read -r PW; [ -n "$PW" ] || exit 1; [ "${DB_ENGINE:-sqlite}" = sqlite ] || { echo "mealie pod already runs DB_ENGINE=$DB_ENGINE; refusing to overwrite it from SQLite" >&2; exit 1; }; export DB_ENGINE=postgres POSTGRES_SERVER=postgres.default.svc.cluster.local POSTGRES_PORT=5432 POSTGRES_USER=mealie POSTGRES_DB=mealie POSTGRES_PASSWORD="$PW"; exec python -'

echo "Copied Mealie's SQLite data into the shared postgres instance"
