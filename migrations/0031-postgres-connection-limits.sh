#!/usr/bin/env bash
# migration: repeatable
# Cap how many connection slots any one app can hold on the shared PostgreSQL
# instance (#1235). On 2026-09-09 all non-superuser slots were consumed for
# ~2.5 minutes and every client was refused; the holder was never identified
# because log_connections was off (it is on now, see apps/postgres/deployment.yaml).
# max_connections is 200 with 5 reserved for superusers, so the 190 granted here
# cannot exhaust the instance even if every role maxes out at once.
#
# NOTE: PostgreSQL does not enforce rolconnlimit for superusers, so the limit on
# `immich` (a superuser by design -- docs/postgres.md) is inert until that role is
# demoted. It is set anyway so the whole budget lives in one place.
#
# authentik is 110 (#1256). 60 was sized from a steady state of 12-13 and an
# observed peak near 40, and it proved to be below the pod's *boot* demand: on
# 2026-09-09 20:42-20:53 UTC the rollout of #1252 produced 525
# "too many connections for role" refusals, authentik-server crash-looped 7
# times and authentik-worker exited 1. The worker's boot fan-out runs one
# outpost_send_update per authentik_outposts_outpost_providers row (25 rows) and
# each task builds its own AsyncConnectionPool(min_size=1, max_size=4) --
# hardcoded in django_channels_postgres/layer.py inside the image, not
# configurable -- reaped only ~4.5 minutes later, so worst-case boot demand is
# ~100 on top of a resting footprint measured at 25-38. Crossing the cap is a
# total SSO outage that then amplifies itself: refusals fail tasks, dramatiq
# retries them, each retry opens another pool. 110 keeps the table sum at 190,
# under the 195 usable slots. Do not lower it without first lowering the boot
# fan-out.
# The Grafana rule "Authentik Postgres Connections Near Role Cap" warns at 90.
#
# claws (#1274): the shared table already summed to 190 of 195 usable slots, so
# onboarding claws-staging's Postgres tenant could not simply append a cap —
# raising max_connections instead means a `strategy: Recreate` restart of this
# whole instance (SSO, Immich, Garden and the Forgejo forge/CI at once, plus the
# authentik-worker wedge in #936), not worth it for a verify-only tenant. Instead
# immich drops from 30 to 10 and claws takes 20, keeping the sum at 190. The
# immich number is inert regardless: PostgreSQL does not enforce rolconnlimit for
# superusers and immich is one by design, and its measured steady state is 1
# connection plus 2-3 more from immich-db-backup's --username=immich. claws caps
# its own client pool at 10 (contract with claws#2953); 20 is boot headroom, per
# the "size from boot demand" rule below.
set -euo pipefail

NS="default"

POD=$(kubectl get pod -n "$NS" -l app=postgres \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$POD" ]; then
  echo "no running postgres pod yet, will retry on next migration run" >&2
  exit 1
fi

OUT=$(kubectl exec -i -n "$NS" "$POD" -- sh -c '
  set -eu
  export PGPASSWORD="$POSTGRES_PASSWORD"
  psql -v ON_ERROR_STOP=1 -qtA -h 127.0.0.1 -U "$POSTGRES_USER" -d postgres -f -
' <<'SQL'
DO $$
DECLARE spec record;
BEGIN
  FOR spec IN SELECT * FROM (VALUES
      ('authentik', 110),
      ('forgejo',   30),
      ('immich',    10),
      ('garden',    20),
      ('claws',     20)
    ) AS t(role_name, conn_limit)
  LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = spec.role_name) THEN
      EXECUTE format('ALTER ROLE %I CONNECTION LIMIT %s', spec.role_name, spec.conn_limit);
    END IF;
  END LOOP;
END
$$;
SELECT count(*) FILTER (WHERE rolconnlimit > 0) || ' ' || count(*)
  FROM pg_roles WHERE rolname IN ('authentik','forgejo','immich','garden','claws');
SQL
)

CAPPED=$(printf '%s\n' "$OUT" | tail -1 | awk '{print $1}')
PRESENT=$(printf '%s\n' "$OUT" | tail -1 | awk '{print $2}')
case "${CAPPED}${PRESENT}" in
  ''|*[!0-9]*) echo "ERROR: unexpected psql output: $OUT" >&2; exit 1 ;;
esac
if [ "$CAPPED" -ne "$PRESENT" ] || [ "$PRESENT" -lt 4 ]; then
  echo "ERROR: only $CAPPED of $PRESENT existing roles carry a connection limit" >&2
  exit 1
fi
echo "connection limits in place on $CAPPED of $PRESENT roles"
