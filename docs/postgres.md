# Shared PostgreSQL

**Depth:** **Reference**
**Read this when:** adding a database to shared `apps/postgres` or touching its NetworkPolicy, connection budgets, or backups.
**Read instead:** the consumer doc, such as [authentik.md](authentik.md) or [immich.md](immich.md), for app-specific wiring.

One PostgreSQL instance in the `default` namespace (`apps/postgres/`) backing Authentik, Immich, Garden, Forgejo and Claws (staging). It replaced the two single-app instances that preceded it — `authentik-postgresql` and the `postgres` sidecar inside the Immich pod (#996).

## Why one Deployment, not an operator

Four databases on a three-node homelab does not justify CloudNativePG or Zalando's operator. Both bring CRDs, a controller Deployment, their own upgrade cadence and their own failure modes, in exchange for HA and automated failover this cluster cannot use: there is a single 24/7 node (`k3s`), the storage node sleeps most of the day, and a `local-path` volume cannot be failed over anyway. A plain `Deployment` with `strategy: Recreate`, one `ReadWriteOnce` PVC and `priorityClassName: critical-infrastructure` is the whole design.

The trade-off is explicit: **there is no automated failover and no point-in-time recovery.** Recovery is from the logical dumps described under [Backups](#backups), which means an RPO of up to 24 hours for Authentik, Garden and Forgejo, and up to 6 hours for Immich.

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

**Gotcha:** the allow-list is enforced by k3s's embedded network-policy controller, which adds a new pod's IP to the ipset a moment *after* the pod starts. A client that connects once, immediately, at container start — a one-shot Job like `forgejo dump` — sees `connection refused` for roughly the first second and fails; long-running servers survive because their ORM init retries. One-shot consumers must wait for the port (`nc -z`) or retry before their first query (see `apps/forgejo/cronjob-backup.yaml`).

`apps/postgres/networkpolicy.yaml` makes the pod default-deny on the pod network and admits port 5432 from two selectors:

- pods labelled `app` in `[authentik-server, authentik-worker, immich, garden, gatus, forgejo, postgres-exporter, datasette-sync, claws-staging]` (`gatus` needs the grant because `apps/gatus/config.yaml` runs a `tcp://postgres.default.svc.cluster.local:5432` uptime probe). The two `forgejo-backup*` CronJobs need no entry of their own — their Job pods carry the same `app: forgejo` label and inherit the grant, which is what lets `forgejo dump` read the database over the pod network. `datasette-sync` is the nightly `db-to-sqlite` exporter behind Datasette (see [datasette.md](datasette.md)); it reads as the superuser over one connection and redacts credential columns before anything is served. `claws-staging` (#1274) covers the `claws-staging-0` pod itself — the nightly openclaw → Postgres sync (claws#2954) runs *inside* that pod via `kubectl exec`, not as a separate client, so no other pod needs a grant
- pods labelled `component: db-backup` (the two backup CronJobs, which carry no `app` label)

**An app added later that is not in that list silently cannot connect** — the symptom is a connection timeout, not a refusal, so it reads like a DNS or a crashloop problem. Extend the list in the same PR that onboards the app.

The migration runner deliberately has no entry. It reaches the database through the apiserver's `pods/exec` endpoint, not over the pod network, so the policy does not apply to it.

## Backups

Two CronJobs, split because one of the two databases can make much stronger assertions about its own content:

| Job | Covers | Schedule | Destination |
|-----|--------|----------|-------------|
| `immich-db-backup` (`apps/immich/`) | `immich` only | every 6h | `/media/backups/immich/` |
| `postgres-db-backup` (`apps/postgres/`) | every other non-template database | daily 02:30 | `/media/backups/postgres/<db>/` |

`postgres-db-backup` enumerates databases at runtime (`pg_database` minus templates, minus `postgres`, minus `immich`), so a database added by a future migration is picked up with no manifest change. `forgejo` is exactly that case — it arrived with `migrations/0030-forgejo-db.sh` (#1216) and needed no manifest change to be backed up, and `claws` (#1274, `migrations/0033-claws-db.sh`) is the same again. Each dump is verified with `pg_restore --list` and a non-zero size before the shared grandfather-father-son retention pass runs, so a corrupt dump can neither be kept nor evict the last good one. `immich` is excluded because `immich-db-backup` already asserts `asset` and `user` row counts and a minimum dump size (#698) — assertions this generic job cannot make.

**Once claws#2954's nightly openclaw → `claws-staging` sync is running, this daily dump to `/media/backups/postgres/claws/` is the only backup of openclaw's claws data that exists anywhere.** As checked on 2026-09-10, nothing on openclaw backs up `~/.claws/claws.db` — no timer, and it is not listed in `config-backups.md`. The dump captures the live openclaw database at ~650 MB, `job_logs` (526 MB / 390k rows) dominating that size. The NAS being off at 02:30 often enough is exactly why `Postgres DB Backup Job Stale` (no *successful* run in 14 days) is the rule that actually proves this backup alive, not the schedule alone.

Both jobs call `sh /scripts/gfs-prune.sh <dir> '*.pgdump'` from the `db-backup-retention-script` ConfigMap (`apps/db-backup-retention-script.yaml`), which keeps everything from the last 2 days, one per day for 14 days, one per week for 8 weeks and one per month for 6 months, ignores files whose names lack a `-YYYYMMDD-HHMMSS` stamp, and runs only after verification.

Both jobs write to the NFS media share and are therefore pinned to `k3s-nas`, which is powered off most of the day. They fail loudly rather than silently skipping when the NAS is unreachable — see [nas-k3s.md](nas-k3s.md).

Both jobs are alerted on. For `postgres-db-backup` the Grafana rules are `Postgres DB Backup Job Failed` (critical; excludes `reason="DeadlineExceeded"`, which is the expected NAS-asleep outcome), `Postgres DB Backup Schedule Missed` (critical; no new Job in 2 days) and `Postgres DB Backup Job Stale` (warning; no *successful* run in 14 days, the rule that actually proves the backup alive given how often the NAS is off at 02:30). The empty-instance exit-0 path is deliberately silent. See [monitoring.md](monitoring.md#cronjob-alerts).

The `postgres-data` PVC itself is **not** in the file-level config backups. A hot `tar` of a live PostgreSQL data directory looks like a backup and will not restore; see [config-backups.md](config-backups.md#not-covered).

## The `immich` role is a superuser

Deliberate, and a real trade-off. Immich creates and updates its own extensions on version upgrade (`vchord`, `vectors`, `cube`, `earthdistance`, `pg_trgm`, `unaccent`, `uuid-ossp`), and its built-in backup feature shells out to `pg_dumpall`. Both need superuser. Running Immich as a plain owner role means every Immich release that touches an extension needs a hand-written migration first.

The cost is that the `immich` role can read and write the Authentik, Garden and Forgejo databases — which since #1216 includes the forge's repository metadata, OAuth clients and session rows. The isolation between apps on this instance is therefore **the NetworkPolicy and the app passwords, not the role grants** — a compromised Immich is a compromise of the whole instance. Accepted for a single-tenant homelab; do not carry the assumption anywhere else.

## Connection limits

`max_connections` is **200**, set as a `-c` flag in `args:` on `apps/postgres/deployment.yaml`
rather than in a config file: the image's entrypoint writes its own
`/etc/postgresql/postgresql.conf`, which `include_if_exists`-es the initdb-generated
`postgresql.conf` inside `PGDATA`, and that file (on the PVC, not in Git) is where the stock
`max_connections = 100` lives. A command-line `-c` outranks both, so it is the only override
that is declarative. `superuser_reserved_connections` is 5, keeping slots for the migration
runner's `psql -U postgres` and the backup CronJobs. `log_connections` and
`log_disconnections` are on so the next squeeze is attributable (#1235).

The stock 100 was already exhausted from 2026-09-09 13:45:01 BST (#1233), roughly 100s
before the Forgejo pod that joined the instance that day (#1216) even started — its own
first connection attempt was refused, ten times over, and it never got a slot. Who held
the other ~55 slots is unattributed: `log_connections` was off at the time. `authentik-worker`
could not connect either and exited 1. Forgejo's `MAX_OPEN_CONNS` defaults to 100 — one client
entitled to every slot on the 100-connection server as it stood that day — so
`apps/forgejo/deployment.yaml` now pins `MAX_OPEN_CONNS=20` / `MAX_IDLE_CONNS=5` /
`CONN_MAX_LIFETIME=3m` — preventive for the next tenant-induced squeeze, not the diagnosed
cause of this one. The same file widens Forgejo's ORM-init retry window to
`DB_RETRIES=20` / `DB_RETRY_BACKOFF=5s` (~100s instead of the default ~30s), because on
2026-09-09 the pod burned all ten default attempts inside the squeeze and exited 1 twice.

**Every new tenant must cap its own pool.** The ceiling is shared and there is no pooler in
front of it; one uncapped client starves every other tenant. Steady state today is ~31–46 of 200
(authentik 25–38, measured 2026-09-09 after #1252 — forgejo 2–5, immich 1, superuser/background 6).
Authentik's resting footprint is ~32 (measured 2026-09-10) and it peaks near 57 for about
five minutes during its 25-task outpost fan-out. Before #1267 that fan-out ran every 65–70
minutes — 12–14 measured times a day, on every `authentik-server` gunicorn worker recycle,
because every ASGI startup re-saves all 25 proxy providers; it now runs roughly once a day,
plus once per server start. The ~100 figure recorded after #1256 was a `25 × max_size` worst
case, not a measurement — see
[authentik.md](authentik.md#connection-footprint-1245). The 38-for-hours figure recorded
earlier (#1235) was one such fan-out whose sessions were never reaped on that container
generation. Check with:

    kubectl exec deploy/postgres -- psql -U postgres \
      -c "select usename, state, count(*) from pg_stat_activity group by 1,2 order by 3 desc;"

Since #1235 the budget is also enforced server-side, so an uncapped or misbehaving client
cannot take the instance down on its own:

| Role | `CONNECTION LIMIT` |
|------|--------------------|
| `authentik` | 110 |
| `forgejo` | 30 |
| `immich` | 10 |
| `garden` | 20 |
| `claws` | 20 |

These are owned by `migrations/0031-postgres-connection-limits.sh`, which carries
`# migration: repeatable` — edit the numbers in place and Flux re-applies them on the next
migration run; there is no new migration to write. The sum is still 190, below the 195
usable slots, so these five roles cannot exhaust the instance between them even at full
stretch. They are **caps, not reservations**: a role over its cap gets
`too many connections for role "x"` and only that app is affected, instead of every client
being refused.

`immich` was lowered from 30 to 10 to make room for `claws` (#1274) without touching
`max_connections` — raising that instead is a `-c` arg, so it needs a `strategy: Recreate`
restart of the whole shared instance (see [Blast radius](#blast-radius-one-restart-now-hits-five-apps)
below), not worth spending on a verify-only tenant. The `immich` limit is **inert** either
way — PostgreSQL does not enforce `rolconnlimit` for superusers, and `immich` is a superuser
by design (see the section above) — and its measured steady state is 1 connection, with
`immich-db-backup` opening 2–3 more as `--username=immich`, so lowering the cap changes
nothing observable. `claws` caps its own client pool at 10 (contract with claws#2953); 20 is
boot headroom, per the sizing rule below.

**Tenant credentials: URL beside the password, not inside it.** `claws-staging` gets a
passwordless `CLAWS_DATABASE_URL=postgres://claws@postgres.default.svc.cluster.local:5432/claws`
plus a separate `CLAWS_DATABASE_PASSWORD` from `claws-db-secret`, and Forgejo takes
`forgejo-db-secret` through its own config — the same split shape for both. That shape is
only safe because each client merges the two itself: node-postgres does **not**. `pg`
re-parses `connectionString` over the config it was given and `pg-connection-string` sets
`password: ""` when the URL has none, so a sibling `password` option is silently dropped and
the client dies with `SASL: SCRAM-SERVER-FIRST-MESSAGE: client password must be a string`
(#1299 — 21 crash-loops on the day the tenant went live). claws#2974 fixed that in the app
(`buildPgConnectionConfig()` merges the password into the URL's userinfo, taking precedence
over any password already there), shipped in image `v2026-09-10.9`; #1300's inline-password
workaround was reverted in #1303. A new node-postgres tenant on an image without that merge
must put the password in the URL. Keep generated tenant passwords alphanumeric
(`migrations/0033-claws-db.sh`) either way — an inline password containing `@ : / ? # %`
would need percent-encoding.

The caps are now individually observable, not just enforced: `Authentik Postgres Connections
Near Role Cap` warns at 90 of authentik's 110, because the instance-wide saturation rule below
fires at 140 backends and can never see a single role approaching its own cap.

`apps/monitoring/postgres-exporter/` runs `postgres_exporter` v0.20.1 against this instance as
the superuser (a non-superuser sees NULL `state`/`usename` for other roles' backends, which
defeats the point), scraped as Prometheus job `postgres-exporter`. Attribution is
`pg_stat_activity_count{usename,datname,state}`, the ceiling is `pg_settings_max_connections`,
and the `Postgres Connection Saturation` rule fires at 70% of it — see
[monitoring.md](monitoring.md#postgres-connection-alerts). The `kubectl exec` one-liner above
remains the offline check when Prometheus itself is the thing that is down.

A cap set below a tenant's real peak is worse than no cap. On 2026-09-09 the `authentik` cap of
60 turned the routine rollout of #1252 into 525 refusals over eleven minutes, seven
`authentik-server` crash-loops and a worker restart (#1256) — the refusals failed dramatiq
tasks, the retries opened more pools, and demand grew for as long as the cap held. Size a cap
from the tenant's *boot* demand, not its steady state, and let the instance-wide 70% saturation
rule catch the case where the sum is genuinely too large.

## Blast radius: one restart now hits five apps

Consolidation trades independence for operational simplicity, and the biggest cost is that a Postgres restart is no longer a single-app event.

`authentik-worker` is the known-bad case. It wedges after a PostgreSQL restart (#936): the pod stays `Ready`, its port-9000 healthcheck keeps returning 200, but every dramatiq task fails on a stale connection, so blueprints stop applying and newly added ForwardAuth hosts start returning 404. The fix is `kubectl rollout restart deployment/authentik-worker`. That behaviour is unchanged by consolidation — but the set of events that can trigger it is now larger, because a restart caused by Immich, Garden or Claws also wedges the worker.

Immich, Garden, Forgejo and Claws (staging) are disrupted by the same restart, though they reconnect on their own. Forgejo raises the stakes rather than the difficulty: a Postgres outage is now a Git-forge outage, and the forge is what runs Forgejo Actions, so CI stops with it. `claws-staging` is the one tenant whose loss is not user-visible — it is verify-only, with no production traffic cut over to it yet. Plan any deliberate restart of this pod as a short outage of SSO, photos, Garden and the forge together, and restart `authentik-worker` afterwards. Verified again on 2026-09-09 after the max_connections rollout: the worker logged 17 `OperationalError: the connection is closed` in two minutes while its port-9000 healthcheck answered 200 throughout — the liveness probe does not catch this, only a manual rollout restart does.

## Related

- [authentik.md](authentik.md) — Authentik's use of the instance
- [immich.md](immich.md) — Immich's use of the instance, restore runbook
- [apps-overview.md](apps-overview.md#secret-migration-jobs) — how migrations run
