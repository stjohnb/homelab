# Immich Photo Management

Immich is a self-hosted photo/video management platform. It runs as a multi-container pod with four containers sharing localhost networking.

## Pod Architecture

```
┌──────────────────────────────────────────────────┐
│ Immich Pod (strategy: Recreate)                  │
│                                                  │
│  ┌──────────────┐  ┌──────────────────────────┐  │
│  │ immich-server│  │ immich-machine-learning  │  │
│  │ Port 2283    │  │ Port 3003               │  │
│  │ v2.5.6       │  │ v2.5.6                  │  │
│  └──────────────┘  └──────────────────────────┘  │
│                                                  │
│  ┌──────────────┐  ┌──────────────────────────┐  │
│  │ postgres     │  │ valkey (Redis alt)       │  │
│  │ Port 5432    │  │ Port 6379               │  │
│  │ pgvecto-rs   │  │ v8.0.2-alpine           │  │
│  └──────────────┘  └──────────────────────────┘  │
└──────────────────────────────────────────────────┘
```

All containers communicate via `localhost` since they share the pod network.

## Containers

### immich-server

The main API and web UI server.

| Setting | Value |
|---------|-------|
| Image | `ghcr.io/immich-app/immich-server:v2.5.6` |
| Port | 2283 |
| CPU | 100m request, 2000m limit |
| Memory | 512 MB request, 4 GB limit |
| Startup probe | HTTP GET `/api/server/ping` — 30s initial, 10s period, 30 failures = ~5.5 min timeout |
| Readiness | HTTP GET `/api/server/ping` (10s period, 3 failures) |
| Liveness | HTTP GET `/api/server/ping` (60s initial, 60s period) |

**Environment**:
- `DB_HOSTNAME=localhost`, `DB_DATABASE_NAME=immich`, `DB_USERNAME=immich`
- `DB_PASSWORD` from secret `immich-db-secret`
- `REDIS_HOSTNAME=localhost`
- `IMMICH_MACHINE_LEARNING_URL=http://localhost:3003`

**Volume**: NFS media PVC mounted at `/usr/src/app/upload` with subPath `photos`.

### immich-machine-learning

Runs CLIP and face detection models for smart search and facial recognition.

| Setting | Value |
|---------|-------|
| Image | `ghcr.io/immich-app/immich-machine-learning:v2.5.6` |
| Port | 3003 |
| CPU | 200m request, 4000m limit |
| Memory | 512 MB request, 4 GB limit |
| Startup probe | HTTP GET `/ping` — 30s initial, 10s period, 27 failures = ~5 min timeout |
| Readiness | HTTP GET `/ping` (10s period, 3 failures) |
| Liveness | HTTP GET `/ping` (10s initial, 60s period) |

**Key environment variables**:
- `MACHINE_LEARNING_PRELOAD__CLIP=ViT-B-32__openai` — preloads CLIP model on startup
- `MACHINE_LEARNING_PRELOAD__FACE=buffalo_l` — preloads face detection model
- `MACHINE_LEARNING_CACHE_TIMEOUT=3600` — keeps models in memory for 1 hour (default 5 min causes frequent reloads)

**Volume**: local-path PVC (`immich-ml-cache-pvc`) mounted at `/cache` for model storage.

**Startup considerations**: Model loading can take several minutes on first boot. The startup probe allows up to ~5 minutes before declaring failure. Preloading avoids cold-start latency on first user request.

### postgres

PostgreSQL with vector extension for ML feature storage.

| Setting | Value |
|---------|-------|
| Image | `tensorchord/pgvecto-rs:pg16-v0.2.0` |
| Port | 5432 |
| CPU | 100m request, 1000m limit |
| Memory | 256 MB request, 1 GB limit |
| Startup probe | `pg_isready -U immich` — 5s initial, 5s period, 30 failures = ~2.5 min timeout |
| Readiness | exec `pg_isready -U immich` (10s period, 3 failures) |
| Liveness | TCP socket on 5432 (30s initial, 30s period) |

**Volume**: local-path PVC (`immich-postgres-pvc`) at `/var/lib/postgresql/data`.

The pgvecto-rs image provides PostgreSQL 16 with the `pgvecto.rs` vector similarity search extension, used by Immich for CLIP embedding storage and smart search.

### valkey

Redis-compatible cache (Valkey is the Redis fork maintained by the Linux Foundation).

| Setting | Value |
|---------|-------|
| Image | `valkey/valkey:8.0.2-alpine` |
| Port | 6379 |
| CPU | 50m request, 500m limit |
| Memory | 64 MB request, 256 MB limit |
| Startup probe | exec `valkey-cli ping` (5s initial, 5s period, 10 failures) |
| Readiness | exec `valkey-cli ping` (10s period, 3 failures) |
| Liveness | TCP socket on 6379 (10s initial, 30s period) |

No persistent storage — cache is ephemeral.

## Storage

| PVC | Storage Class | Mount | Purpose |
|-----|---------------|-------|---------|
| `media-pvc` | NFS | `/usr/src/app/upload` (subPath: photos) | Photo/video files |
| `immich-postgres-pvc` | local-path | `/var/lib/postgresql/data` | Database |
| `immich-ml-cache-pvc` | local-path | `/cache` | ML model cache |

The media PVC is shared with other services (Sonarr/Radarr use subPaths `tv` and `movies` from the same NFS share).

## Secrets

| Secret | Keys | Purpose |
|--------|------|---------|
| `immich-db-secret` | `password` | PostgreSQL password (shared between server and DB containers) |

## Database Backup

A CronJob (`immich-db-backup`) backs up the PostgreSQL database to NFS every 6 hours.

A physical copy of the pre-migration PG16 data directory also exists at `/mnt/SSD-POOL/media/backups/k3s-pvcs-20260728/immich-postgres-pvc/`, recovered from the destroyed storage VM's zvol alongside the logical `immich-db-20260727-185837.pgdump` — two independent restore paths for that point in time. Immich's PVCs are deliberately excluded from the nightly `config-backup` CronJob: `immich-postgres-pvc` is already covered by the logical dump below (a hot `tar` of a live PostgreSQL data directory would be torn and is worse than useless), and `immich-ml-cache-pvc` is regenerable. See [config-backups.md](config-backups.md).

| Setting | Value |
|---------|-------|
| Schedule | `0 */6 * * *` (every 6 hours, Europe/London) |
| Format | `pg_dump --format=custom` (compressed, supports selective restore) |
| Location | `/mnt/SSD-POOL/media/backups/immich/` on NFS media share |
| Retention | 14 most recent backups |
| Job deadline | 30 minutes (`activeDeadlineSeconds: 1800`) — covers NFS mount wait time when the NAS is coming back online |
| Retries | `backoffLimit: 1` — one pod retry per run, **except** an empty-database refusal (exit 3), which `podFailurePolicy: FailJob` ends immediately with no retry |
| Image | `postgres:16-alpine` (pg_dump built-in) |
| Content assertion | asset & user row counts > 0; dump > 17 MB; pg_restore --list TOC check |
| Exit codes | 3 = empty database → `Immich Database Is Empty` (warning, Slack only); 1 = any other backup fault → `Immich DB Backup Job Failed` (critical); DeadlineExceeded = NFS unavailable, not alerted |

### NAS Availability

The NAS is not always on and shuts down at 3 AM on days it runs. The 3 AM shutdown schedule predates the NixOS migration and has not been re-verified; the WoL wake path via `truenas-gate` is unchanged. The CronJob runs every 6 hours (midnight, 6 AM, noon, 6 PM) to maximize the chance of catching an availability window. The backup job probes PostgreSQL availability with `pg_isready`, retrying up to 10 times at 60-second intervals (~10 minutes), and **fails** if Postgres is still unreachable after that — an extended outage is now visible rather than silently skipped. When NFS is unavailable, the pod stays Pending (can't mount the PVC), gets killed by the active deadline (`activeDeadlineSeconds: 1800`), and is recorded as a Failed job with `reason="DeadlineExceeded"`. This is expected — `failedJobsHistoryLimit: 1` and `successfulJobsHistoryLimit: 3` keep the job history clean, and the `reason!="DeadlineExceeded"` filter on the `Immich DB Backup Job Failed` alert excludes exactly this case from paging.

The `activeDeadlineSeconds: 1800` covers the case where the NAS is coming back online and the init container must wait for the NFS PVC to mount before the backup can start — `pg_dump` itself has no internal timeout.

### Backup Validation

Before dumping, the job asserts `select count(*) from asset` and `select count(*) from "user"` are both non-zero, and refuses to run `pg_dump` at all if either is zero. After dumping, it verifies `pg_restore --list` can read the file and that its table of contents includes `TABLE DATA` entries for both `public.asset` and `public.user`, and that the file exceeds a 17,000,000-byte floor. That floor sits just above the largest geodata-only dump observed — 16,676,446–16,676,452 bytes, measured across backups taken between 2026-05-19 and 2026-07-28 while the database held no user data. Any assertion failure removes the bad dump and exits non-zero *before* the retention `rm` runs, so a bad dump can neither be kept nor evict the last good one. The empty-database refusal exits 3 and raises `Immich Database Is Empty` (`warning`, 30m pending, Slack only, no GitHub issue) because it is a known state needing manual recovery, not a backup malfunction. Every other assertion failure exits 1 and raises `Immich DB Backup Job Failed` (`critical`); that rule now filters `reason!~"DeadlineExceeded|PodFailurePolicy"`.

### History

`immich-postgres-pvc` (`local-path`, node-local disk) was lost when the k3s worker VM was rebuilt on 2026-04-09/10. Every backup taken since captured only reference tables (`geodata_places`, `naturalearth_countries`, etc.) with no `user`, `asset`, or `album` rows, but reported success because the job only checked `pg_dump`'s exit status, which is 0 even for an empty database. This went undetected until 2026-07-28, when Immich presented its first-user setup screen after an unrelated storage migration. See issue #698.

**Recovered 2026-08-10 (issues #725, #774, #726, #779, #780).** Between 2026-04-09/10 (data loss) and 2026-08-10 the database sat empty — the row-count assertion added in #716 correctly refused every 6-hourly backup during that window, and the empty-DB refusal itself kept re-filing `[k3s] Workload failing: default/immich-db-backup` alerts (#726, #779) from an external monitor outside this repo (distinct from the in-cluster Grafana alerts documented in [monitoring.md](monitoring.md) — see that doc's "External monitors" note) until those issues were closed by hand; that channel has no per-workload opt-out. Recovery was entirely manual, not a code change: a fresh admin user was created by hand, then a one-off `immich-go` (v0.32.0) Job re-imported the orphaned originals from `/usr/src/app/upload/upload` (owner UUID `409b90bd-2559-4d4f-ace2-57de6f137703`, 33.2 GB) — 29,118 assets uploaded, 1 local duplicate, 0 errors. A manual backup run then completed and verified (`immich-db-20260810-150404.pgdump`, 24.1 MB, asset=29118 user=1) — the first real dump since the 2026-04-09/10 loss. The stale failed Job that `k3s-monitor` kept re-reading was deleted. **Album/user metadata from before the loss (albums, shared links, favorites, face-recognition state) was not recoverable — only EXIF/file-derived metadata survives** via the re-import; treat this as a fresh library with the original files, not a full restore.

Two follow-ups remain open, called out by the repo owner when closing #779 — track them as separate issues before assuming either is done:
- **GFS retention**: the flat "keep 14 most recent" policy (see table above) gives only ~3.5 days of history at the 6-hour schedule — every dump taken before the 2026-04-09/10 loss was rotated away long before the empty-database bug was noticed on 2026-07-28, leaving nothing to restore from. A GFS-style retention (e.g. keep dailies for a month, weeklies for a quarter) would have made this recoverable and should be designed into the next iteration of this CronJob.
- **Orphan cleanup**: the pre-recovery orphan tree (originals + thumbnails, ~42 GB) is still sitting on NFS alongside the newly re-imported library. Delete it only after a verification period confirms the re-import is complete and stable — don't delete it as a drive-by cleanup.

### Verifying Backups

```bash
# Check recent job runs
kubectl get jobs -l app=immich,component=db-backup

# Check CronJob status
kubectl get cronjob immich-db-backup

# List backups on NFS (from a node with NFS access)
ls -lht /mnt/SSD-POOL/media/backups/immich/
```

### Restore Procedure

```bash
# Scale down Immich first
kubectl scale deployment immich --replicas=0

# Launch a temporary pod with the NFS media volume
kubectl run pg-restore --rm -it --image=postgres:16-alpine \
  --overrides='{
    "spec": {
      "volumes": [{"name": "media", "persistentVolumeClaim": {"claimName": "media-pvc"}}],
      "containers": [{
        "name": "pg-restore",
        "image": "postgres:16-alpine",
        "volumeMounts": [{"name": "media", "mountPath": "/media"}],
        "command": ["bash"]
      }]
    }
  }' -- bash

# Inside the pod, set the password and restore:
export PGPASSWORD='<password-from-immich-db-secret>'
pg_restore --host=immich-postgres --username=immich --dbname=immich \
  --clean --if-exists /media/backups/immich/immich-db-YYYYMMDD-HHMMSS.pgdump
```

The `--clean --if-exists` flags drop and recreate database objects, making this a full restore. Scale Immich back up after restoring: `kubectl scale deployment immich --replicas=1`.

## Deployment Notes

- **Strategy: Recreate** — only one pod at a time (database can't be shared)
- **terminationGracePeriodSeconds: 90** — allows PostgreSQL time for WAL flush, checkpoint, and vector index serialization during shutdown. Applies to the entire pod (all four containers).
- **enableServiceLinks: false** — prevents Kubernetes from injecting service env vars that can collide with Immich's own port variables. This was the original proof-of-concept for the setting; it's since been applied fleet-wide, see [Key Patterns in apps-overview.md](apps-overview.md#enableservicelinks).
- **NAS dependency**: Photo storage is on NFS from `k3s-nas` (NixOS, not TrueNAS — see [nas-k3s.md](nas-k3s.md)). Pod starts but can't serve photos if the NAS is offline. Routed through truenas-gate for graceful degradation.
- **Excluded from Flux health checks**: Immich depends on NFS from the NAS, which is intentionally not always available. When the NAS is offline, the pod can't mount the NFS volume, the deployment hits `ProgressDeadlineExceeded`, and Flux detects it as stalled. Since the apps Kustomization reconciles every 1 minute, this would fire Slack error alerts every minute — even though the NAS being offline is expected. Immich is monitored through truenas-gate and Gatus instead.
- **Startup probes**: All four containers have startup probes to prevent premature liveness/readiness probe kills during slow starts (database recovery, migrations, ML model loading). Liveness and readiness probes only activate after the startup probe succeeds.
- **Readiness probes**: All four containers have readiness probes. Since all containers share one pod, the pod is only marked Ready when all containers pass readiness — correct behavior since the server can't serve properly if postgres or ML isn't ready.
- **Postgres service selector**: `immich-postgres` (service-postgres.yaml) selects `app: immich, component: server` — the tighter `component: server` label prevents backup job pods or other ad-hoc pods with `app: immich` from accidentally joining the postgres service endpoints (self-routing bug fix).
- **Domain**: immich.home.bstjohn.net (via truenas-gate → immich:2283)

## Modifying

When upgrading Immich, update the image tag for both `immich-server` and `immich-machine-learning` simultaneously — they must run the same version. The database and cache images are independent.
