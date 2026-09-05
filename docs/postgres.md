# Shared PostgreSQL

**Reference.** Read this when adding a database to the shared `apps/postgres` instance or touching its NetworkPolicy/backups. For a specific consumer, see [authentik.md](authentik.md) or [immich.md](immich.md).

One PostgreSQL instance in the `default` namespace (`apps/postgres/`) backing Authentik, Immich and Garden. It replaced the two single-app instances that preceded it — `authentik-postgresql` and the `postgres` sidecar inside the Immich pod (#996).

## Why one Deployment, not an operator

Three databases on a three-node homelab does not justify CloudNativePG or Zalando's operator. Both bring CRDs, a controller Deployment, their own upgrade cadence and their own failure modes, in exchange for HA and automated failover this cluster cannot use: there is a single 24/7 node (`k3s`), the storage node sleeps most of the day, and a `local-path` volume cannot be failed over anyway. A plain `Deployment` with `strategy: Recreate`, one `ReadWriteOnce` PVC and `priorityClassName: critical-infrastructure` is the whole design.

The trade-off is explicit: **there is no automated failover and no point-in-time recovery.** Recovery is from the logical dumps described under [Backups](#backups), which means an RPO of up to 24 hours for Authentik and Garden, and up to 6 hours for Immich.

| Setting | Value |
|---------|-------|
| Image | `ghcr.io/immich-app/postgres:16-vectorchord0.4.3` (digest-pinned) |
| Port | 5432 (ClusterIP `postgres`) |
| Storage | 20 Gi, local-path (`postgres-data`, `subPath: pgdata`) |
| CPU | 100m request, 2000m limit |
| Memory | 256 Mi request, 2 Gi limit |
| Priority | `critical-infrastructure` |
| Termination grace | 90s (WAL flush + checkpoint) |
| Node | `k3s` only — `nodeAffinity` excludes the GPU and storage nodes |

The `nodeAffinity` block is not an optimisation. The volume is `local-path`, so it is bound to whichever node first scheduled the pod; pinning it to the 24/7 node is what keeps the database up while `ryzen` and `k3s-nas` are powered off.

## Image choice: why not `postgres:16-alpine`

Immich stores CLIP and face embeddings in vector columns and needs a vector index extension **inside the same server** — the index lives in the database, not in the application. Consolidating onto stock `postgres:16-alpine` would mean Immich could not run at all. `ghcr.io/immich-app/postgres` is upstream Immich's own image: stock PostgreSQL 16 plus VectorChord (`vchord`).

Two consequences follow from using that image for every database:

- **Do not add a `command:` override.** The image ships `/usr/local/bin/immich-docker-entrypoint.sh`, which rewrites `postgresql.conf` to preload `vchord.so`. Replacing the entrypoint silently removes the extension, and any table with a `vector`-typed column then fails to open.
- **Because the entrypoint rewrites `postgresql.conf`, do not assume local `trust` authentication.** Inside the pod, connect over TCP with a password (`psql -h 127.0.0.1 -U "$POSTGRES_USER"` with `PGPASSWORD="$POSTGRES_PASSWORD"` from the container's own environment) rather than over the unix socket.

The image carried a `-pgvectors0.2.0` suffix while Immich's data was migrated. That variant also preloaded the legacy pgvecto.rs (`vectors`) extension, so the dump taken from the old Immich instance could be restored while it still held `vectors`-typed objects. Immich has since reindexed onto VectorChord and `migrations/0027-immich-drop-pgvecto-rs.sh` dropped the extension, so the image is now plain `16-vectorchord0.4.3`.

`vectors.so` is no longer preloaded. **Never roll Immich back below v1.133**: older releases write `vectors`-typed objects that this image cannot open, and recovering from that means restoring a dump onto the `-pgvectors` variant again.

## The `postgres-superuser` secret

The superuser password is generated in-cluster by `migrations/0024-postgres-superuser.sh` and stored in the `postgres-superuser` Secret (key `POSTGRES_PASSWORD`). It is never in Git.

The generator produces 48 **alphanumeric** characters. That restriction is load-bearing: the later per-app migrations interpolate passwords into SQL string literals, so a value containing a quote or a backslash would break `CREATE ROLE`.

On a fresh cluster the postgres pod sits in `CreateContainerConfigError` until that migration runs and creates the Secret. This is expected and self-healing — the same behaviour Authentik has always had — not something to "fix" with an initContainer.

## Adding a database for a new app

Roles and databases are created **only** by numbered migration scripts that `kubectl exec` into the running pod. Never use `/docker-entrypoint-initdb.d`: that directory runs once, on first initialisation of an empty data directory, so any app onboarded after the volume was created is silently skipped.

`migrations/0025-authentik-db.sh` is the copy-paste template. The shape is:

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_PW=$(kubectl get secret <app>-secret -n default -o jsonpath='{.data.<key>}' | base64 -d)
[ -n "$APP_PW" ] || { echo "no app password available" >&2; exit 1; }

NEW_POD=$(kubectl get pod -n default -l app=postgres \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
[ -n "$NEW_POD" ] || { echo "no running postgres pod yet, will retry" >&2; exit 1; }

printf '%s\n' "$APP_PW" | kubectl exec -i -n default "$NEW_POD" -- sh -c '
  set -eu
  IFS= read -r APP_PW
  [ -n "$APP_PW" ] || { echo "no password on stdin" >&2; exit 1; }
  export PGPASSWORD="$POSTGRES_PASSWORD"
  P="psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U $POSTGRES_USER -tAc"
  ...create role, create database, load data, assert row counts...
'
```

Rules that are not optional:

- **Never pass a password as a `kubectl exec` argument.** Every argv after `--` becomes a `command=` query parameter captured verbatim by Kubernetes audit logging. Feed it on stdin (#902). CI's `migration-exec-secrets` job enforces this.
- **Add every Secret the script reads to `migrations/rbac.yaml`** in a `resourceNames` list with verb `get`. RBAC denial returns Forbidden, not NotFound, which makes the usual idempotency guard permanently inoperative (#923). CI's `migration-secret-rbac` job enforces this.
- **Assert on data, not exit status.** `pg_restore` and `pg_dump` exit 0 on an empty database. End the script with a row count on a table that must be non-empty and drop the half-restored database if the assertion fails, so a retry starts clean.
- **Add the app to the NetworkPolicy allow-list** (below) and to `apps/postgres/cronjob-db-backup.yaml`'s expectations if it needs anything beyond the default dump.
- Scripts are **one-shot** — `migration-state` keys on the filename, so editing a `completed:` script has no effect on an existing cluster.

## NetworkPolicy allow-list

`apps/postgres/networkpolicy.yaml` makes the pod default-deny on the pod network and admits port 5432 from two selectors:

- pods labelled `app` in `[authentik-server, authentik-worker, immich, garden, gatus]` (`gatus` needs the grant because `apps/gatus/config.yaml` runs a `tcp://postgres.default.svc.cluster.local:5432` uptime probe)
- pods labelled `component: db-backup` (the two backup CronJobs, which carry no `app` label)

**An app added later that is not in that list silently cannot connect** — the symptom is a connection timeout, not a refusal, so it reads like a DNS or a crashloop problem. Extend the list in the same PR that onboards the app.

The migration runner deliberately has no entry. It reaches the database through the apiserver's `pods/exec` endpoint, not over the pod network, so the policy does not apply to it.

## Backups

Two CronJobs, split because one of the two databases can make much stronger assertions about its own content:

| Job | Covers | Schedule | Destination |
|-----|--------|----------|-------------|
| `immich-db-backup` (`apps/immich/`) | `immich` only | every 6h | `/media/backups/immich/` |
| `postgres-db-backup` (`apps/postgres/`) | every other non-template database | daily 02:30 | `/media/backups/postgres/<db>/` |

`postgres-db-backup` enumerates databases at runtime (`pg_database` minus templates, minus `postgres`, minus `immich`), so a database added by a future migration is picked up with no manifest change. Each dump is verified with `pg_restore --list` and a non-zero size before the shared grandfather-father-son retention pass runs, so a corrupt dump can neither be kept nor evict the last good one. `immich` is excluded because `immich-db-backup` already asserts `asset` and `user` row counts and a minimum dump size (#698) — assertions this generic job cannot make.

Both jobs call `sh /scripts/gfs-prune.sh <dir> '*.pgdump'` from the `db-backup-retention-script` ConfigMap (`apps/db-backup-retention-script.yaml`), which keeps everything from the last 2 days, one per day for 14 days, one per week for 8 weeks and one per month for 6 months, ignores files whose names lack a `-YYYYMMDD-HHMMSS` stamp, and runs only after verification.

Both jobs write to the NFS media share and are therefore pinned to `k3s-nas`, which is powered off most of the day. They fail loudly rather than silently skipping when the NAS is unreachable — see [nas-k3s.md](nas-k3s.md).

Both jobs are alerted on. For `postgres-db-backup` the Grafana rules are `Postgres DB Backup Job Failed` (critical; excludes `reason="DeadlineExceeded"`, which is the expected NAS-asleep outcome), `Postgres DB Backup Schedule Missed` (critical; no new Job in 2 days) and `Postgres DB Backup Job Stale` (warning; no *successful* run in 14 days, the rule that actually proves the backup alive given how often the NAS is off at 02:30). The empty-instance exit-0 path is deliberately silent. See [monitoring.md](monitoring.md#cronjob-alerts).

The `postgres-data` PVC itself is **not** in the file-level config backups. A hot `tar` of a live PostgreSQL data directory looks like a backup and will not restore; see [config-backups.md](config-backups.md#not-covered).

## The `immich` role is a superuser

Deliberate, and a real trade-off. Immich creates and updates its own extensions on version upgrade (`vchord`, `vectors`, `cube`, `earthdistance`, `pg_trgm`, `unaccent`, `uuid-ossp`), and its built-in backup feature shells out to `pg_dumpall`. Both need superuser. Running Immich as a plain owner role means every Immich release that touches an extension needs a hand-written migration first.

The cost is that the `immich` role can read and write the Authentik and Garden databases. The isolation between apps on this instance is therefore **the NetworkPolicy and the app passwords, not the role grants** — a compromised Immich is a compromise of the whole instance. Accepted for a single-tenant homelab; do not carry the assumption anywhere else.

## Blast radius: one restart now hits three apps

Consolidation trades independence for operational simplicity, and the biggest cost is that a Postgres restart is no longer a single-app event.

`authentik-worker` is the known-bad case. It wedges after a PostgreSQL restart (#936): the pod stays `Ready`, its port-9000 healthcheck keeps returning 200, but every dramatiq task fails on a stale connection, so blueprints stop applying and newly added ForwardAuth hosts start returning 404. The fix is `kubectl rollout restart deployment/authentik-worker`. That behaviour is unchanged by consolidation — but the set of events that can trigger it is now larger, because a restart caused by Immich or Garden also wedges the worker.

Immich and Garden are disrupted by the same restart, though they reconnect on their own. Plan any deliberate restart of this pod as a short outage of SSO, photos and Garden together, and restart `authentik-worker` afterwards.

## Related

- [authentik.md](authentik.md) — Authentik's use of the instance
- [immich.md](immich.md) — Immich's use of the instance, restore runbook
- [apps-overview.md](apps-overview.md#secret-migration-jobs) — how migrations run
