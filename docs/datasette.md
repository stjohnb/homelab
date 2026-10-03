# Datasette

**Depth:** **Reference**
**Read this when:** touching `apps/datasette/`, the nightly Postgres export or media-app SQLite snapshots, or the redaction rules that gate what reaches them.
**Read instead:** [postgres.md](postgres.md) for the databases, or [authentik.md](authentik.md) for ForwardAuth wiring.

Datasette (`apps/datasette/`) is a read-only browser at `datasette.home.bstjohn.net` over redacted nightly snapshots of the shared PostgreSQL databases and of the media apps' own SQLite databases (Sonarr, Radarr, Prowlarr, Bazarr, Seerr, Jellyfin — see [SQLite sources](#sqlite-sources)). It was decommissioned in #911 as unused and restored in #1248 with an export pipeline attached.

## Why there is an export pipeline at all

**Datasette cannot connect to PostgreSQL.** It is SQLite-only — `datasette serve /data` scans a directory for `*.db` files and serves what it finds. The supported route from PostgreSQL is Simon Willison's [`db-to-sqlite`](https://github.com/simonw/db-to-sqlite), which copies whole databases into SQLite files.

So "connect Datasette to Postgres" is really a nightly copy. **The data Datasette serves is a daily snapshot, never live.** Anything written to PostgreSQL today shows up here tomorrow morning.

## The nightly job

`datasette-sync` (`apps/datasette/cronjob-sync.yaml`) runs at **03:30 Europe/London**, after `postgres-db-backup` at 02:30 so the two do not contend for the instance. For each database it finds in `pg_database` (non-template, minus the empty `postgres` maintenance database) it:

1. exports it with `db-to-sqlite --all` into `/work`, an `emptyDir`;
2. runs `redact.py` over that file in place;
3. `VACUUM INTO`s the result onto the served PVC as `<db>.db.new`, then `mv`s it into place.

**Only redacted, vacuumed files ever reach the served volume.** That ordering is the controlling invariant, not an implementation detail: `VACUUM INTO` copies live pages only, so a value overwritten by the redaction pass cannot survive in a freelist page of the served file. The raw export never leaves the `emptyDir` and dies with the pod.

The export runs as an **initContainer**; the only real container is a `kubectl rollout restart deployment/datasette`. Datasette enumerates `*.db` at startup and holds their file descriptors, so a new snapshot is picked up only by a restart — and putting the export first means a failed export leaves the previous snapshot served and never triggers the restart. A per-database failure isolates: the loop continues, the Job exits 1, and the intermediate `.db.new` name is not matched by Datasette's `*.db` scan, so a partially written file is never served.

Both the Deployment and the Job carry the same gpu/storage `DoesNotExist` `nodeAffinity`. `datasette-data` is a `ReadWriteOnce` `local-path` volume mounted by both, which is legal only while they share a node. Drop the affinity from either and the second pod hangs in `ContainerCreating`.

`datasette-sync` reads as the superuser over a single connection, so it needs no `CONNECTION LIMIT` of its own. It does need its pod label (`app: datasette-sync`) in the `apps/postgres/networkpolicy.yaml` allow-list — without it the job **times out** rather than being refused, the documented silent-failure mode.

## SQLite sources

A second CronJob, `datasette-sync-sqlite` (`apps/datasette/cronjob-sync-sqlite.yaml`, script `sync-sqlite.sh` in the same ConfigMap), publishes the media apps' SQLite databases so the whole media pipeline can be queried in one place. It is separate from the Postgres job so a failure in either never blocks the other. If some sources fail, the snapshot step still exits 0 and records `published`/`failed` markers; the restart container restarts Datasette when anything published and then fails the Job when anything failed; Datasette is restarted after each, so it restarts twice a night.

| App | Source | Copy method | Served as |
|-----|--------|-------------|-----------|
| Sonarr | `./sonarr.db` in the newest `/media/backups/config/sonarr/sonarr-config-*.tar.gz` | `config-backup`'s online-backup copy | `sonarr.db` |
| Radarr | `./radarr.db` in the newest `radarr-config-*.tar.gz` | same | `radarr.db` |
| Bazarr | `./db/bazarr.db` in the newest `bazarr-config-*.tar.gz` | same | `bazarr.db` |
| Prowlarr | `prowlarr-local-config-pvc` `/prowlarr.db` | Python `sqlite3` online backup (`snapshot.py`) | `prowlarr.db` |
| Seerr | `seerr-config` `/db/db.sqlite3` | same | `seerr.db` |
| Jellyfin | `jellyfin-config` `/data/jellyfin.db` | same | `jellyfin.db` |
| Jellyfin library | `jellyfin-config` `/data/library.db`, only if present | same | `jellyfin-library.db` |

`logs.db` is never served. None of the served names collide with a Postgres database name.

**Why 02:35, not 03:30.** Sonarr, Radarr and Bazarr keep their databases on node-local PVCs on `k3s-nas`, which a `k3s` pod cannot mount, and the NAS is only awake ~02:03–03:03 ([config-backups.md](config-backups.md#why-these-times)). So the servarr copies come from `config-backup`'s nightly archives on the hard `media-pvc`, whose `.db` members are already SQLite online-backup copies. 02:35 is after `config-backup`'s 02:30 deadline, so no archive is mid-write, and 02:35 + `activeDeadlineSeconds: 1200` ends by 02:55, before the 03:03 poweroff. A night the NAS is asleep leaves the pod in `ContainerCreating` until the deadline and every source keeps its previous snapshot.

**Archive-age guard.** A servarr source whose newest archive is older than 2 days fails, so a dead `config-backup` cannot keep this job green while it re-serves an old archive.

**Prowlarr, Seerr and Jellyfin** live on `k3s`, so their PVCs are mounted directly, **read-write**, and copied with Python's `sqlite3.Connection.backup()` — the same online backup API as `sqlite3 .backup`, so no `apk`/`apt` install is needed. A plain `cp` of a live WAL database can be torn; this cannot. Read-write is required because the backup creates a `-shm` beside the source. The `snapshot` initContainer therefore runs as **root with `drop: [ALL]` plus `DAC_READ_SEARCH`, `DAC_OVERRIDE` and `CHOWN`**, mirroring `config-backup-players`: the files are owned by uid 1000 (Prowlarr, Seerr) or 0 (Jellyfin), and any `-wal`/`-shm` it recreates is `chown`ed back afterwards so the app can still write. Its files on `/data` are root-owned beside the 65534-owned Postgres exports; each script touches only its own filenames.

Each source then follows the same invariant as the Postgres export: raw copy in the `/work` `emptyDir`, `redact.py` with that app's rules, `VACUUM INTO` `/data/<name>.db.new`, `PRAGMA journal_mode=DELETE` on the new file (the copies carry the source's WAL header, and Datasette must not need a `-shm` beside a served file), then `mv` into place. A failure in any step logs `ERROR: <name> failed`, deletes the `.db.new`, keeps the previous snapshot served and carries on with the next source; the job exits 1 at the end so the failure still alerts.

**Jellyfin 10.11 has no live `library.db`.** The 10.11 upgrade merged the library into `jellyfin.db` and renamed the old file `library.db.old`, so `jellyfin-library.db` is published only if `library.db` exists; its absence is a `WARN`, not a failure.

## Redaction

The exports derive from databases holding Authentik password hashes, Forgejo tokens and Immich API keys, and the media apps' databases hold indexer, download-client and application API keys and Jellyfin/Seerr user tokens. `redact.py` (in the `datasette-sync-script` ConfigMap) applies up to four layers, keyed by the database name passed to it.

**Layer 1 — whole-table purges.** Tables whose entire contents are credential or session material are `DELETE`d:

| Database | Purged |
|----------|--------|
| `authentik` | `authentik_core_token`, `authentik_core_session`, `authentik_core_authenticatedsession`, `authentik_flows_flowtoken`, the four `authentik_providers_oauth2_*` token tables, `authentik_providers_proxy_proxysession`, `authentik_providers_rac_connectiontoken`, `authentik_providers_saml_samlsession`, `authentik_crypto_certificatekeypair`, `authentik_enterprise_license`, `authentik_policies_unique_password_userpasswordhistory`, the five `authentik_stages_authenticator_*` device tables, `django_session`, `django_postgres_cache_cacheentry`, `django_channels_postgres_groupchannel` |
| `forgejo` | `session`, `forgejo_auth_token`, `two_factor`, `webauthn_credential`, `oauth2_grant`, `oauth2_authorization_code`, `external_login_user`, `push_mirror`, `hook_task`, `system_setting` (can hold the mailer password), `email_hash` |
| `immich` | `session`, `api_key` |
| `sonarr`, `radarr`, `prowlarr` | `Config` (the app's key/value settings), `Commands`, `PendingReleases` (indexer payloads and download URLs) |
| `jellyfin` | `ApiKeys`, `Devices` (per-device access tokens) |
| `seerr` | `session`, `user_push_subscription` |
| `bazarr` | `table_settings_notifier` (Apprise URLs carry bot tokens and webhook secrets in the path, which no column name or query-parameter scrub reveals) |

They are deleted **after** export rather than skipped during it. `db-to-sqlite` adds foreign keys as a final pass, and Immich's `session` is FK-referenced (by itself and by `session_sync_checkpoint`) — skipping it would fail the whole export.

**Layer 1b — named column overwrites**, for credentials Layer 2's name pattern cannot see. Applied only where the table and column exist:

| Database | Overwritten |
|----------|-------------|
| `sonarr`, `radarr`, `prowlarr` | the JSON `Settings` column of `Indexers`, `DownloadClients`, `Notifications`, `ImportLists`, `NetImport`, `Metadata`, `Applications` (Prowlarr's copy of the Sonarr/Radarr API keys) and `IndexerProxies`, plus `IndexerStatus.LastRssSyncReleaseInfo` → `[redacted]` |
| `jellyfin` | `Users.Password`, `Users.EasyPassword` → `NULL` (falling back to `[redacted-<rowid>]` where `NOT NULL`) |
| `seerr` | `user.jellyfinAuthToken`, `user.plexToken` → `[redacted]` (Layer 2 also matches these; listed so they never depend on it) |

**Layer 2 — column-name pattern redaction**, applied to every table of every database, so a column some future upstream migration adds is covered with no edit to this repo. Any column whose name matches `passwd|password|secret|token|salt|hash|credential|cookie|session|nonce|otp|totp|mfa|passcode|scratch|keytab|encrypted|jwt|signature|private|pin_?code|apikey|key` is overwritten with `[redacted]` (or `[redacted-<rowid>]` where a `UNIQUE` index forbids a constant). SQLite is dynamically typed, so writing a string into an `INTEGER`-affinity column is legal and still satisfies `NOT NULL`.

**Layer 3 — value scrub, `sonarr`/`radarr`/`prowlarr`/`bazarr` only.** Parameter names also match with a prefix (e.g. `access_token=`). Known gap: passkeys carried as a URL path segment (`/download/<id>/<passkey>`) are not scrubbed. Every non-key text value is passed through a regex that rewrites `apikey=`, `api_key=`, `passkey=`, `rsskey=`, `torrent_pass=`, `token=`, `secret=`, `password=` and `auth=` query parameters, and the same names as JSON string fields (plus `accesstoken`), to `[redacted]`. This catches the Prowlarr API key embedded in `History.Data`/`DownloadHistory.Data` download URLs (`…/download?apikey=…`), which no column name reveals. It is scoped to the servarr databases because they are small and the cost is a regex per value. Where a scrubbed value would collide with a `UNIQUE` index, the value becomes `[redacted-<rowid>]`.

**Primary-key, foreign-key and generated columns are exempt.** Redacting a PK or FK would break row identity and Datasette's link navigation; a generated column cannot be `UPDATE`d at all.

The pattern **deliberately errs wide**. It also hits harmless things — `must_change_password` booleans, `package_blob.hash_sha256` content hashes, `signature_algorithm` — and those come out as `[redacted]` too. Over-redacting a boolean is cheaper than missing one secret. The only exceptions are the five Immich metadata key/value tables and Forgejo's `user_setting`, where "key" is a map key rather than a secret.

**The residual is real and accepted.** A deny-list cannot promise completeness: a future upstream column named something like `client_material` matches nothing and would be exported in the clear. An allow-list would blank most of the schema, so the mitigation is the access posture below plus the whole-table purge list.

## Skipped tables

Six tables are `--skip`ped at export. Nothing foreign-keys into any of them, so `db-to-sqlite`'s FK pass still succeeds.

| Table | Why |
|-------|-----|
| `immich.smart_search`, `immich.face_search` | 155 MB each, and `vector`-typed — no SQLite mapping |
| `immich.geodata_places`, `immich.naturalearth_countries` | 117 MB / 8.8 MB of bulk reference data |
| `authentik.authentik_tasks_tasklog` | 82 MB of task tracebacks, which is both bulky and a plausible place for credential material to surface in an error string |
| `claws.job_logs` | 526 MB / 390k rows of free-text agent log output, the same credential-in-an-error-string risk as Authentik's task log |

Database sizes for scale: immich 561 MB, authentik 137 MB, forgejo 23 MB, garden 7.7 MB, claws ~120 MB after the job_logs skip — hence the 10 Gi PVC.

## Access

**Home only.** `datasette.home.bstjohn.net`, behind the `authentik-auth` ForwardAuth chain, bound to the `infra` group. There is deliberately **no `.ext.` host and no ext provider** — the `.ext.` tombstones in `apps/authentik/configmap-blueprints.yaml` stay `state: absent`. Even fully redacted the snapshots still hold user emails, group membership and repo/library metadata, which is not something to publish to the tailnet edge.

## Operational notes

- **The first run is empty.** After merge Datasette serves an empty database list until 03:30. Expected and self-healing. Do not add an export initContainer to the Deployment — the CronJob's own rollout restart would re-trigger it in a loop.
- **Hand-maintained pip pins.** Three packages are `pip install`ed at runtime inside the `sync.sh` script string in `apps/datasette/sync-script.yaml`, into the writable `/tmp` `emptyDir` (the container is `readOnlyRootFilesystem`): `db-to-sqlite==1.5`, `psycopg2-binary==2.9.11` and `SQLAlchemy==2.0.54`. Renovate does not bump them (they are not in a manifest it tracks), so they must be bumped by hand. fleet-infra builds no images (#1189), so there is nothing to bake them into. If PyPI is unreachable the job fails and the previous snapshot keeps being served.
- **Install `psycopg2-binary`, never the `db-to-sqlite[postgresql]` extra.** That extra resolves to plain `psycopg2`, which publishes no Linux wheels; pip would try to build it from source and die on the missing compiler and `pg_config`, failing every nightly run. `psycopg2-binary` provides the same importable `psycopg2` module from a manylinux wheel — which is also why the base image is `python:3.14.7-slim` and not an Alpine tag, as manylinux wheels do not install on musl.
- **The `export` initContainer fails within seconds with `ModuleNotFoundError: No module named 'psycopg'`.** This happens when SQLAlchemy 2.1.0+ is released and pip resolves it: SQLAlchemy 2.1 changed bare `postgresql://` URLs to resolve to psycopg (v3) instead of psycopg2, but this job only installs `psycopg2-binary`. Evidence: the pod ends in `Init:Error` and the job log shows the import failure. The runs from 2026-09-25 onward failed this way (#1596). Fix: pin `SQLAlchemy==2.0.54` and use explicit `postgresql+psycopg2://` URLs in both the shell `URL` variable and the inline Python `create_engine()` call, so the driver is explicit and version-independent. Triage tell: if the export dies before printing `databases: ...`, a dependency release has likely changed. Do not migrate to psycopg3.
- **The PVC is not backed up** and does not need to be. Everything on it is regenerable from PostgreSQL and the app databases by the next nightly runs.
- **SQLite snapshot alerts.** `Datasette SQLite Sync Job Failed` fires when a `datasette-sync-sqlite` run fails for any reason other than `DeadlineExceeded` (the NAS-asleep signature); the log names the source. `Datasette SQLite Sync Job Stale` fires when the job has not fully succeeded for **3 days**, the backstop for the NAS window making silent staleness the likely failure. Only a fully green run advances the success timestamp, so one persistently failing source also fires it. See [monitoring.md](monitoring.md).
- **Renaming a `config-backup` archive member or path breaks the servarr snapshots.** `sync-sqlite.sh` extracts `./sonarr.db`, `./radarr.db` and `./db/bazarr.db` by exact name; a missing member fails that source.
- Gatus probes `http://datasette:8001/-/versions.json` internally, bypassing ForwardAuth.

## Related

- [postgres.md](postgres.md) — the shared instance, its NetworkPolicy allow-list and backups
- [authentik.md](authentik.md) — ForwardAuth providers, groups and policy bindings
