# Datasette

**Depth:** **Reference**
**Read this when:** touching `apps/datasette/`, the nightly Postgres export, or the redaction rules that gate what reaches it.
**Read instead:** [postgres.md](postgres.md) for the databases, or [authentik.md](authentik.md) for ForwardAuth wiring.

Datasette (`apps/datasette/`) is a read-only browser over the shared PostgreSQL databases at `datasette.home.bstjohn.net`. It was decommissioned in #911 as unused and restored in #1248 with an export pipeline attached.

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

## Redaction

The exports derive from databases holding Authentik password hashes, Forgejo tokens and Immich API keys. `redact.py` (in the `datasette-sync-script` ConfigMap) applies two layers.

**Layer 1 — whole-table purges.** Tables whose entire contents are credential or session material are `DELETE`d:

| Database | Purged |
|----------|--------|
| `authentik` | `authentik_core_token`, `authentik_core_session`, `authentik_core_authenticatedsession`, `authentik_flows_flowtoken`, the four `authentik_providers_oauth2_*` token tables, `authentik_providers_proxy_proxysession`, `authentik_providers_rac_connectiontoken`, `authentik_providers_saml_samlsession`, `authentik_crypto_certificatekeypair`, `authentik_enterprise_license`, `authentik_policies_unique_password_userpasswordhistory`, the five `authentik_stages_authenticator_*` device tables, `django_session`, `django_postgres_cache_cacheentry`, `django_channels_postgres_groupchannel` |
| `forgejo` | `session`, `forgejo_auth_token`, `two_factor`, `webauthn_credential`, `oauth2_grant`, `oauth2_authorization_code`, `external_login_user`, `push_mirror`, `hook_task`, `system_setting` (can hold the mailer password), `email_hash` |
| `immich` | `session`, `api_key` |

They are deleted **after** export rather than skipped during it. `db-to-sqlite` adds foreign keys as a final pass, and Immich's `session` is FK-referenced (by itself and by `session_sync_checkpoint`) — skipping it would fail the whole export.

**Layer 2 — column-name pattern redaction**, applied to every table of every database, so a column some future upstream migration adds is covered with no edit to this repo. Any column whose name matches `passwd|password|secret|token|salt|hash|credential|cookie|session|nonce|otp|totp|mfa|passcode|scratch|keytab|encrypted|jwt|signature|private|pin_?code|apikey|key` is overwritten with `[redacted]` (or `[redacted-<rowid>]` where a `UNIQUE` index forbids a constant). SQLite is dynamically typed, so writing a string into an `INTEGER`-affinity column is legal and still satisfies `NOT NULL`.

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
- **`db-to-sqlite` is `pip install`ed at runtime**, pinned to `1.5`, into the writable `/tmp` `emptyDir` (the container is `readOnlyRootFilesystem`). fleet-infra builds no images (#1189), so there is nothing to bake it into. If PyPI is unreachable the job fails and the previous snapshot keeps being served.
- **Install `psycopg2-binary`, never the `db-to-sqlite[postgresql]` extra.** That extra resolves to plain `psycopg2`, which publishes no Linux wheels; pip would try to build it from source and die on the missing compiler and `pg_config`, failing every nightly run. `psycopg2-binary` provides the same importable `psycopg2` module from a manylinux wheel — which is also why the base image is `python:3.12.7-slim` and not an Alpine tag, as manylinux wheels do not install on musl.
- **The PVC is not backed up** and does not need to be. Everything on it is regenerable from PostgreSQL by the next nightly run.
- Gatus probes `http://datasette:8001/-/versions.json` internally, bypassing ForwardAuth.

## Related

- [postgres.md](postgres.md) — the shared instance, its NetworkPolicy allow-list and backups
- [authentik.md](authentik.md) — ForwardAuth providers, groups and policy bindings
