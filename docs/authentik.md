# Authentik SSO

**Depth:** **Reference**
**Read this when:** adding SSO to a service or touching Authentik's ForwardAuth/OIDC providers, blueprints, or groups.
**Read instead:** [postgres.md](postgres.md) for the shared database Authentik depends on.

Authentik provides centralized single sign-on (SSO) for homelab services using Traefik's ForwardAuth middleware. Located in `apps/authentik/`.

## Architecture

```
User → Traefik Ingress
         │
         ├── authentik-strip-headers  (removes client-sent auth headers)
         ├── authentik-forwardauth    (validates session with Authentik)
         │        ↓
         │   Authentik Server (:9000)
         │        │
         │   200 OK → forward with user headers
         │   401    → redirect to login page
         │
         └── Backend Service (with X-authentik-* headers)
```

Traefik intercepts requests to protected services and sends a subrequest to Authentik's embedded outpost. If the user has a valid session, Authentik returns HTTP 200 and Traefik **overwrites** the `X-authentik-*` headers on the forwarded request with values from Authentik's response. Client-supplied values for those headers are replaced, not appended.

## Components

```
authentik/
├── kustomization.yaml
├── deployment-server.yaml          # Authentik server (API + embedded outpost)
├── deployment-worker.yaml          # Authentik async worker
├── service-server.yaml             # Server: port 9000, 9300 (metrics)
├── ingress.yaml                    # auth.home.bstjohn.net
├── middleware-strip-headers.yaml   # Traefik: clear auth headers from client
├── middleware-forwardauth.yaml     # Traefik: ForwardAuth to the embedded outpost (.home.)
├── middleware-chain.yaml           # Traefik: strip → forwardauth chain
├── deployment-proxy-ext.yaml       # Standalone proxy outpost for the .ext. hosts
├── service-proxy-ext.yaml          # Ext outpost: port 9000, 9300 (metrics)
├── middleware-forwardauth-ext.yaml # Traefik: ForwardAuth to the ext outpost (.ext.)
├── middleware-chain-ext.yaml       # Traefik: strip → forwardauth-ext chain
├── middleware-strip-authentik-headers.yaml # Traefik: clear X-authentik-* only (keeps Authorization)
├── middleware-strip-authorization.yaml     # Traefik: clear Authorization after ForwardAuth
├── middleware-chain-basic.yaml     # Traefik: Basic-auth-capable chain (.home. Grafana/Prometheus)
├── middleware-chain-basic-ext.yaml # Traefik: Basic-auth-capable chain (.ext. Grafana/Prometheus)
└── configmap-blueprints.yaml       # Declarative provider + application config
```

### Server

| Setting | Value |
|---------|-------|
| Image | `ghcr.io/goauthentik/server:2026.8.3` |
| Ports | 9000 (HTTP), 9443 (HTTPS), 9300 (Prometheus metrics) |
| CPU | 100m request, 1000m limit |
| Memory | 512 MB request, 1536 MB limit |
| `/dev/shm` | `emptyDir{medium: Memory}`, 256Mi |
| Priority | `critical-infrastructure` |
| Strategy | Recreate |
| Liveness | HTTP GET `/-/health/live/` port 9000 |
| Readiness | HTTP GET `/-/health/ready/` port 9000 |

The embedded outpost serves the 12 `.home.` proxy providers, and a standalone `authentik-proxy-ext` Deployment (`ghcr.io/goauthentik/proxy`, `AUTHENTIK_HOST_BROWSER=https://auth.ext.bstjohn.net`, authenticated with the outpost's auto-generated `ak-outpost-<uuid>-api` token, whose key the blueprint pins to `authentik-secrets/EXT_OUTPOST_TOKEN`) serves the 12 `.ext.` providers — the browser-facing login host is a per-outpost setting, so a single outpost would bounce every `.ext.` login through `auth.home.bstjohn.net` (#1111). The `ext-proxy-outpost` blueprint entry is identified by `name`, never by a pinned `pk`: the blueprint importer assigns an `identifiers.pk` as a plain string, and authentik's synchronous `Outpost` `post_save` receiver evaluates `self.uuid.hex`, so a pinned pk raises `AttributeError: 'str' object has no attribute 'hex'` and rolls back the entire `forwardauth-apps` blueprint on every reconcile — which is how the outpost, its service account and its token all silently failed to exist while the proxy pod crash-looped on `403 Token invalid/expired` (#1116, #1118). The outpost's service account is found by its display name (`Outpost ext-proxy-outpost Service-Account`), which authentik derives from the outpost name rather than its uuid; a blueprint token entry must also carry `user` and `intent` or `TokenSerializer.validate` rejects it (#1118). The embedded outpost's ForwardAuth endpoint is `http://authentik-server.default.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik` (FQDN required because the ForwardAuth middleware is resolved by Traefik, which runs in the `traefik` namespace and cannot resolve short service names in `default`). Both server and worker mount the blueprints ConfigMap at `/blueprints/custom`.

**`/dev/shm` sizing**: gunicorn's tmpfs-backed shared memory (worker heartbeat/temp files) needs more than the containerd default 64Mi — an undersized `/dev/shm` causes the kernel to deliver **SIGBUS** to the gunicorn worker on an `mmap` page fault, crashlooping the pod (`signal: bus error` immediately after "applying django migrations", while PostgreSQL connections keep succeeding). The fix is a dedicated `dshm` `emptyDir{medium: Memory, sizeLimit: 256Mi}` volume mounted at `/dev/shm`. Because tmpfs usage counts against the container's memory cgroup, `limits.memory` was raised from 1Gi to 1536Mi alongside it — adding the shm volume without the limit increase can re-trigger the same SIGBUS under memory pressure.

#### Ext outpost probes and the cold-start kill (#1419)

The `authentik-proxy-ext` outpost does not bind `:9000` until it has fetched its configuration
from `authentik-server`. The original `initialDelaySeconds: 20` liveness probe therefore
killed it approximately 50 seconds into any start where the server was still coming up (evidenced
on 2026-09-16 13:51 UTC node reboot, killed at 13:52:28, the same second it logged `Successfully
connected websocket` and loaded its 13 `.ext` applications). A `startupProbe` (`periodSeconds: 10`,
`failureThreshold: 30`) now holds liveness and readiness off for up to 5 minutes of grace while
the server comes up, and must not be removed — it is the only protection against a cold start
restarting the pod. The pod's historically high restart count (150 shown on live cluster) is
almost entirely historical: 148 came from the #1116 blueprint/token failure, only 2 from this
probe bug, and will reset when the pod is recreated.

### Worker

| Setting | Value |
|---------|-------|
| Image | `ghcr.io/goauthentik/server:2026.8.3` (same image, `worker` arg) |
| CPU | 50m request, 500m limit |
| Memory | 512 MB request, 1 GB limit |
| Priority | `standard` |
| Liveness | HTTP GET `/-/health/live/` port 9000 (worker `ak-axum` health server), 5 failures × 30s |
| Readiness | HTTP GET `/-/health/ready/` port 9000, 3 failures × 10s |
| Startup | HTTP GET `/-/health/live/` port 9000, 30 failures × 10s |

Handles async tasks (email, background jobs, blueprint processing). Shares the same database connection as the server.

#### Worker probes and the stale-connection wedge (#936)

`ak healthcheck` in worker mode only checks the worker's PID file — it never touches PostgreSQL. During the 2026-08-25/26 NAS outage, the `authentik-postgresql` pod restarted and the worker's psycopg connections died; because the liveness/readiness probes never noticed, the pod stayed `Running`/`Ready` for ~15h while every background task silently failed. Blueprint changes merged during that window — the Awtrix providers from #917 and the Homepage provider from #933/#934 — were never applied, producing Authentik 404s on `home.bstjohn.net` and both Awtrix hostnames until a manual `kubectl rollout restart deployment/authentik-worker`.

The fix wired liveness/readiness/startup probes to port 9000. On 2026.5 and earlier that port was the worker process's own `WorkerHealthcheckMiddleware` HTTP server (`authentik/tasks/middleware.py`), answering on `/`. Its handler looped over every Django DB connection, forced a reconnect, and returned 503 if any connection failed — so a dead PostgreSQL link would fail liveness and the pod would restart instead of wedging silently — in theory. In practice the probe's own fork reconnected successfully while the dramatiq consumer fork stayed wedged, so the probe returned 200 and the pod was never restarted; a manual rollout restart was the fix.

**Caveat (2026.5 and earlier)**: that healthcheck ran in its own fork with its own Django connections, so it detected "worker pod cannot reach PostgreSQL" but still returned 200 if only the dramatiq consumer fork (the one actually running tasks) was wedged. That narrower failure mode is covered by the `Authentik` Grafana alert group (see [docs/monitoring.md](monitoring.md)), not by the probe.

**Since 2026.8 the port-9000 listener is different.** Authentik 2026.8 removed that middleware and replaced the worker's port-9000 server with the Rust `ak-axum` worker server (upstream `src/worker/healthcheck.rs`). It serves only `/-/health/ready/` and `/-/health/live/` — the trailing slash is required — and returns 404 for everything else, including `/`. After #1620 bumped the images to 2026.8.3, the unchanged `/` probes returned 404: kubelet killed the healthy worker about every 5 minutes (the 30 × 10s startup threshold), background tasks were interrupted on each kill, the metrics Service lost its Ready endpoint, and the "Authentik Worker Metrics Target Down" and "Workload Pod Not Ready" alerts fired until the paths were corrected. Readiness (`/-/health/ready/`) runs `SELECT 1` from the Rust supervisor's own DB pool and then asks the Python worker whether it is ready; liveness (`/-/health/live/`) only checks that the worker process is alive. The startup and liveness probes use `/-/health/live/`, readiness and the Gatus `Authentik Worker` endpoint use `/-/health/ready/`. Nobody has verified whether the new readiness check detects the #936 dramatiq-fork wedge; a manual `kubectl rollout restart deployment/authentik-worker` remains the documented recovery.

**On every Authentik train bump, confirm the worker probe paths against the running container before calling the upgrade done.** `kubectl logs deploy/authentik-worker` shows each probe request's `path` and `status` under the `authentik_axum::tracing` target (the log strips the `/-` prefix, so `/-/health/ready/` appears as `/health/ready/`); a 404 there means the manifest path is stale.

The worker `Service` (`apps/authentik/service-worker.yaml`) also exposes port 9000, so the Gatus `Authentik Worker` endpoint can probe it directly.

Since #996 the worker's connections point at the shared `postgres` instance, so the blast radius of a restart is wider: any restart of that pod drops connections for Immich and Garden as well as Authentik, and the worker will still wedge in exactly the way described above if the probes ever regress.

On 2026-09-09 the 100-slot ceiling on the shared instance was exhausted for ~2.5 minutes
before the Forgejo pod that joined that day (#1216) even started, so who held the slots is
unattributed (`log_connections` was off; it is on now). The worker could not connect either
and exited 1, firing the `Authentik Worker Database Errors` alert (#1233). The ceiling is now
200, per-role caps are in `migrations/0031-postgres-connection-limits.sh`, and Forgejo's pool
(`MAX_OPEN_CONNS` defaults to 100) is capped at 20 as prevention against the next
tenant-induced squeeze — see [postgres.md](postgres.md#connection-limits). **Do not read the
port-9000 probes as self-healing**: on 2026.5 the worker wedged after a PostgreSQL restart with
the probe still returning 200 (#936, re-confirmed 2026-09-09), and whether the 2026.8 `ak-axum`
readiness check catches that wedge is unverified. Plan on
`kubectl rollout restart deployment/authentik-worker` by hand.

### Upgrades

Authentik releases are `YYYY.M` trains (2026.2, 2026.5, 2026.8, …) and every train is a major upgrade in all but version string. Since 2026.8, `lifecycle/migrate.py` `ensure_allowed_version` runs before any system or Django migration and aborts with `Major version skips are not allowed` unless the latest row in the DB's `authentik_version_history` table is on the current train or the immediately previous one (`VERSION_FAMILY_PREVIOUS` in `authentik/__init__.py`). Server, worker and `proxy-ext` move together — upstream requires outposts to match the server version — so bump the three image tags in `apps/authentik/deployment-*.yaml` one train at a time and wait for `authentik-server` to be Ready (which writes the new version into `authentik_version_history`) before taking the next train. On every train bump, also confirm the worker probe paths against the running container before calling the upgrade done: 2026.8 replaced the worker's port-9000 health server and the old `/` probes returned 404 (see "Worker probes and the stale-connection wedge" above).

Renovate enforces the human gate: `ghcr.io/goauthentik/*` **minor** updates carry `major-update` (never `Automerge`) plus a PR-body note about train changes; **patch** updates within a train still auto-merge. This exists because on 2026-09-24 Renovate's grouped `authentik` PR #1593 was classed as a minor update, auto-merged, and jumped `2026.2.1 → 2026.8.3` in one step. Server and worker both crash-looped at the version check before serving, `proxy-ext` never became Ready, and every SSO login failed until #1596 stepped the images forward to `2026.5.7` (2026.8.3 had not touched the DB, and the 2026.5 train has no skip check, so it migrated cleanly from 2026.2.1). Renovate then re-proposes 2026.8.3 as a human-gated PR.

### PostgreSQL

Authentik uses the shared instance in [`apps/postgres/`](postgres.md) — `AUTHENTIK_POSTGRESQL__HOST: postgres` on both the server and the worker, database `authentik`, role `authentik`, password from `authentik-secrets`/`PG_PASS`.

| Setting | Value |
|---------|-------|
| Host | `postgres` (Service in `default`, see [postgres.md](postgres.md)) |
| Port | 5432 |
| Database / role | `authentik` / `authentik` |
| Storage | Shared `postgres-data` PVC (20 Gi, local-path) |

#### Connection footprint (#1245)

Resting footprint is 25–38 connections: 9 from `authentik-worker` (one dramatiq process × two
threads — the consumer, the scheduler's two `pg_advisory_unlock` holders, the
`authentik_tasks_workerstatus` heartbeat, cache reads, `SET search_path`) plus **16+** from
`authentik-server` (`LISTEN "channels_messages"`, a `django_channels_postgres_groupchannel`
insert, a request connection — measured 2026-09-09 after #1252; the previously recorded 3
predates that change), with un-reaped fan-out sessions pushing the observed floor to 38.

Peak is ~57 (resting plus the burst) and before #1267 it happened **12–14 times a day** —
measured, one recycle every 65–70 minutes: 25 × `authentik.outposts.tasks.outpost_send_update`,
one per `authentik_outposts_outpost_providers` row (13 embedded + 12 ext), plus
2 × `outpost_controller`. The trigger is not a worker restart and not the blueprint import.
`authentik/providers/proxy/apps.py` defines `proxy_set_defaults` as a
`@ManagedAppConfig.reconcile_tenant`, which `ManagedAppConfig.ready()` connects to the
`startup` signal sent from `authentik/root/asgi.py` on every ASGI lifespan startup; it
re-saves **every** `ProxyProvider` unconditionally, and each save fires
`outpost_related_post_save`, which enqueues one `outpost_send_update` per outpost the provider
belongs to (the task takes an *outpost* pk and is not deduplicated by `uid`). So every server
start costs a full fan-out. What made it a dozen-plus times a day was gunicorn recycling its
single worker: 12 `Booting worker` lines and exactly 300 `Provider changed, rebuilding
permissions and sending update` lines in one 24 h window, 14 and 350 in the next, with no pod
restart.

**Cost of one new ForwardAuth service: 2 provider rows, 2 extra fan-out tasks, and 2–8 extra
Postgres connections held for ~4.5 minutes** (one `-home` row on the embedded outpost, one
`-ext` row on `ext-proxy-outpost`; each task's pool is `min_size=1`, so 2 is typical and 8 the
ceiling under retry pressure). Datasette, Browser and Pages are the exceptions at 1 row each — they are home-only.

Every task in that fan-out builds its own `AsyncConnectionPool(min_size=1, max_size=4)` —
hardcoded in
`/ak-root/packages/django-channels-postgres/django_channels_postgres/layer.py`
(`CHANNEL_LAYERS` in `/authentik/root/settings.py` takes no options, so there is no env var
for it). The often-quoted ~100-connection boot demand is a `25 × max_size` worst case, not a
measurement; the measured burst is ~25 connections on top of the resting footprint. On
2026-09-09, a pod rollout of #1252 landed on top of one of these fan-outs while the role was
capped at 60, and produced 525 `FATAL: too many connections for role "authentik"` over
20:42–20:53 UTC, `PoolTimeout: pool initialization incomplete after 30.0 sec` on every
`outpost_send_update`, seven `authentik-server` crash-loops and one worker restart (exit 1)
before it drained (#1256).

The failure amplifies itself twice over. Each refusal fails a task and dramatiq retries it,
opening another pool; and the kubelet liveness probe kills the pod, which re-runs the whole
25-task fan-out on the next start. That probe's `/-/health/live/` on port 9000 is served by
the Go router, not Django (no `kube-probe` entries reach the Django access log):
`internal/web/proxy.go` answers it by synchronously GETting gunicorn's own
`/-/health/live/` — Django's `LiveView`, no DB round-trip — under User-Agent
`goauthentik.io/router/healthcheck`, and returns 502 when that fails. With `workers=1` there
is no worker to answer during a recycle: ~8 s measured, ~6 s of it inside the 25 provider
re-saves, which is why the default 1 s probe timeout fails on *every* recycle (a `Liveness
probe failed: context deadline exceeded` event, count 5). Under a squeeze the re-save phase
stalls, three failures land inside 45 s and kubelet SIGTERMs the pod — the #1256 container's
`lastState` is `exitCode 0, reason Completed`, a kubelet kill rather than a crash. The
router's own "gunicorn process failed healthcheck three times, restarting" loop
(`attemptStartBackend` in `internal/web/web.go`) ticks every 30 s on `IsRunning()`, so it needs
90 s and never fired first. Since #1267 the kubelet tolerance is ~2 minutes, which makes that
router loop the first responder: an in-place gunicorn restart, still re-running `wait_for_db`,
migrations and the startup re-save, but without cycling the pod. And because the recycle is
stretched to roughly once a day, a fan-out coinciding with a rollout is a once-a-day risk
rather than a dozen-times-a-day one. Side benefit: the readiness probe also failed once per
recycle, dropping the pod out of the Service for 10–20 s and blipping every ForwardAuth host;
roughly-daily recycles remove those blips too.

Levers that look plausible but do not help: `postgresql.use_pool` is force-disabled at
`/authentik/lib/config.py:336`; `conn_max_age` already defaults to 0 at `config.py:357` and
raising it would make the footprint worse, not better; pgbouncer transaction pooling breaks
the LISTEN/NOTIFY that the channel layer and task broker depend on; the outposts cannot be
merged to halve the fan-out (#1111).

What is actually set, and why:

- `AUTHENTIK_WEB__WORKERS=1` on `authentik-server` — halves the Django request-connection
  ceiling from 2×4 to 1×4 (`/lifecycle/gunicorn.conf.py` defaults). Threads are deliberately
  left at the default 4. Resting footprint measured 22–23 connections on 2026-09-10.
- `AUTHENTIK_WORKER__PROCESSES=1` / `AUTHENTIK_WORKER__THREADS=2` on `authentik-worker` —
  already the upstream defaults, pinned so an image bump cannot silently raise them.
- `AUTHENTIK_OUTPOSTS__DISCOVER=false` on both — `automountServiceAccountToken: false` means
  the Kubernetes service connection authentik would otherwise try can never work; the flag is
  read by both the server and worker processes, so it must be set on both.
- `GUNICORN_CMD_ARGS=--max-requests 20000 --max-requests-jitter 2000` on `authentik-server`
  — `/lifecycle/gunicorn.conf.py` hardcodes `max_requests = 1000` / `max_requests_jitter = 50`
  as plain literals, so **`AUTHENTIK_WEB__MAX_REQUESTS` is not a config key and does nothing**;
  only `web.workers` and `web.threads` go through `CONFIG.get_int` there. gunicorn applies
  `GUNICORN_CMD_ARGS` after the config file (`Application.load_config`), so it overrides them.
  This moves the recycle — and its 25-task outpost fan-out — from every 65–70 minutes
  (12–14 measured per day) to roughly once a day, while keeping a memory-leak backstop.
  Do not set 0.
- `livenessProbe: timeoutSeconds 5, failureThreshold 8` on `authentik-server` — the defaults
  (1 s / 3) made kubelet fail the probe on every worker recycle and SIGTERM the pod under a
  squeeze, seven kills in eleven minutes (#1256), each one re-running the fan-out.

The `authentik` role's cap is 110 in `migrations/0031-postgres-connection-limits.sh`, sized
from boot demand rather than steady state, with the Grafana rule `Authentik Postgres
Connections Near Role Cap` warning at 90 (see
[monitoring.md](monitoring.md#postgres-connection-alerts)). 110 is the largest value that
keeps the four-role budget under the 195 usable slots. Do not tighten it until the boot
fan-out itself shrinks; a role hitting its cap is a total SSO outage (`too many connections
for role`), not graceful degradation.

The dedicated `authentik-postgresql` Deployment, Service and NetworkPolicy were removed in #996 after migration `0025-authentik-db.sh` copied the database into the shared instance. `pvc-postgresql.yaml` was retained for one PR as an unmounted rollback copy and has since been deleted.

Authentik 2026.2 has no Redis dependency: cache uses `django_postgres_cache`, the channel layer uses `django_channels_postgres`, and sessions are DB-backed (`authentik.core.sessions`) — all Postgres. A previously deployed `authentik-redis` (Redis 7, `AUTHENTIK_REDIS__HOST` env var on server/worker) was leftover from an older Authentik version; before removal it showed 0 keys and only 3 commands processed (the diagnostic session itself) over 136 days of uptime, confirming it was unused. It was removed in #828 along with its unauthenticated, cluster-reachable port 6379. Do not re-add Redis — if a rollback to an Authentik version older than ~2025.2 is ever needed, the manifests are recoverable from this commit's git history.

**NetworkPolicy**: access control moved with the database. `apps/postgres/networkpolicy.yaml` restricts ingress on port 5432 to pods labeled `app: authentik-server`, `app: authentik-worker`, `app: immich`, `app: garden` or `app: gatus` (the last for its `tcp://postgres...:5432` uptime probe), plus the backup CronJob — the same pattern the removed `networkpolicy-postgresql.yaml` used. This still closes off the other 30+ pods in `default` from reaching Postgres directly; it holds session, cache, channel-layer and task state for the SSO system fronting every protected service. Adding a new consumer means extending that allow-list, or it silently cannot connect.

## Blueprints (Declarative Configuration)

Authentik applications and proxy providers are configured declaratively via blueprints in `configmap-blueprints.yaml`. The ConfigMap is mounted into both the server and worker at `/blueprints/custom`. Authentik auto-discovers and applies blueprints on startup and periodically thereafter.

`grafana-provider-home` is the first and only provider using `skip_path_regex` (Unauthenticated Paths), added so the `dashpi` wall display can iframe a Grafana public dashboard with no login. Patterns are unanchored Rust regexes matched against the request path in `forward_single` mode, and a pattern that fails to compile is skipped with only a warning in the outpost log — so a typo silently leaves the path authenticated rather than failing loudly.

The blueprint defines three custom `authentik_providers_oauth2.scopemapping` entries: `groups-scope-mapping` (attached to the OIDC providers, emits the `groups` claim), `grafana-role-scope-mapping` (attached only to `grafana-provider-home` and `grafana-provider-ext`, emits the `X-authentik-grafana-role` upstream header — see [Grafana Integration](#grafana-integration)), and `email-verified-scope-mapping` (attached only to `mealie-oidc-provider`; emits `email` and `email_verified` sourced from the user's `attributes.email_verified` blueprint attribute rather than Authentik's built-in `scope_name: email` mapping, which hardcodes `email_verified: false`). Because two mappings now share `scope_name: email`, every other OIDC provider references the built-in mapping unambiguously by its managed id, `goauthentik.io/providers/oauth2/scope-email`, instead of by `scope_name`.

The blueprint defines:
- **29 ForwardAuth proxy providers** (13 services × home + ext domain, plus Datasette, Browser and Pages home-only) + **29 proxy applications**: the 16 home providers on the embedded outpost, the 13 ext providers on the `ext-proxy-outpost`
- **12 OIDC providers** (Mealie, Jellyfin, Jellyseerr, Seerr, Headlamp, Proxmox, Bin Scraper, Claws, Forgejo, Home Assistant, Container Registry, Garden) + **12 OIDC applications**, using native OAuth2/OIDC integration + **12 provider-less `(ext)` bookmark applications** (`<slug>-ext`, `meta_launch_url` on the `.ext.` host) so the library on `auth.ext` links to ext hosts (#1118); the OIDC login itself still uses the fixed `auth.home` issuer
- **4 groups**, **2 users**, and **82 policy bindings** (29 ForwardAuth + 12 OIDC ext bookmark applications × 2 bindings each). Both users carry `attributes.email_verified: true` for the Mealie scope mapping above; blueprint `attributes` on a user replace the whole attributes dict on apply, so an unlisted future user (or one added without this attribute) is treated as unverified.

Both outposts are declaratively configured in the blueprint via `authentik_outposts.outpost` entries that list their proxy providers by `!KeyOf` reference — the **embedded outpost** carries the 16 `-home` providers, the **`ext-proxy-outpost`** the 13 `-ext` ones. This ensures provider-to-outpost attachment is version-controlled and reproducible. Critical invariant, applying to both entries: every `!KeyOf` reference in an outpost's `providers` list must point to a provider with `state: present` — referencing an absent provider causes the entire outpost entry to fail to apply.

### ForwardAuth Proxy Providers

Each service except the home-only ones (Datasette, Browser, Pages) has a matching `-ext` provider (`<svc>-forward-auth-ext`, slug `<svc>-ext`) whose `external_host` is the `.ext.bstjohn.net` sibling — the outpost selects the provider from `X-Forwarded-Host`, so a host with no provider gets a 404 (#1109). Because the ext providers sit on the `ext-proxy-outpost`, a login started on an `.ext.` host redirects to `auth.ext.bstjohn.net` and never touches a `.home.` host (#1111). ForwardAuth sessions are still per-host cookies, so users log in separately on `.home.` and `.ext.`.

| Service | Provider | Application Slug |
|---------|----------|-----------------|
| Sonarr | `sonarr-forward-auth-home` | `sonarr` |
| Radarr | `radarr-forward-auth-home` | `radarr` |
| Prowlarr | `prowlarr-forward-auth-home` | `prowlarr` |
| Bazarr | `bazarr-forward-auth-home` | `bazarr` |
| Transmission | `transmission-forward-auth-home` | `transmission` |
| Grafana | `grafana-forward-auth-home` | `grafana` |
| Prometheus | `prometheus-forward-auth-home` | `prometheus` |
| Homepage | `homepage-forward-auth-home` | `homepage` |
| Awtrix Kitchen | `awtrix-kitchen-forward-auth-home` | `awtrix-kitchen` |
| Awtrix Office | `awtrix-office-forward-auth-home` | `awtrix-office` |
| Navidrome | `navidrome-forward-auth-home` | `navidrome` |
| Music Assistant | `music-assistant-forward-auth-home` | `music-assistant` |
| Datasette | `datasette-forward-auth-home` | `datasette` |
| growth-engine | `growth-engine-forward-auth-home` | `growth-engine` |
| Browser | `browser-forward-auth-home` | `browser` |

### Awtrix: ForwardAuth + Injected Basic-Auth

Both clocks sit behind ForwardAuth *and* a `headers` middleware (`awtrix-basic-auth-header`, `apps/awtrix/middleware-basicauth.enc.yaml`, SOPS-encrypted) that injects the device's own HTTP Basic credential so SSO users are not prompted twice. The middleware is chained *after* `authentik-auth`, whose `authentik-strip-headers` step clears any client-supplied `Authorization` first. Direct LAN access to `192.168.0.30` / `192.168.0.160` remains gated only by the device's Basic auth — the proxy cannot prevent it.

### Navidrome: Split Router for Subsonic Clients (#962)

Navidrome is the only ForwardAuth service with a split router: a single `traefik.io/v1alpha1` `IngressRoute` (`apps/navidrome/ingress.yaml`) carries four routes for the same host, three of them — `/rest`, `/share` and `/ping` — pinned to `priority: 100` with no middleware so they bypass ForwardAuth, plus a catch-all `Host()` route (default rule-length-derived priority, lower than 100) carrying the `authentik-auth` middleware chain. This keeps Subsonic clients (Symfonium, Amperfy, play:Sub, substreamer, Feishin) working — they authenticate with their own token scheme and cannot complete an interactive Authentik browser login. An earlier two-Ingress design was consolidated into this single IngressRoute because two Ingress/IngressRoute resources claiming the same host fail `scripts/check-ingress-uniqueness.sh`. Navidrome has no OIDC; instead `ND_EXTAUTH_USERHEADER=X-authentik-username` maps the ForwardAuth session onto a Navidrome user via header-based external auth (`ND_EXTAUTH_*` env vars). The pre-existing admin account was renamed `admin` → `brendan` before #962 merged so SSO lands on that account rather than auto-creating a duplicate; any Subsonic client still configured with username `admin` must be switched to `brendan`. Other users are auto-provisioned on first UI load with an autogen password. `navidrome-ingress-from-traefik-only` (`apps/navidrome/networkpolicy.yaml`) is what prevents in-cluster header spoofing, since `ND_EXTAUTH_TRUSTEDSOURCES` trusts the entire pod CIDR.

### OIDC Providers

Several services use Authentik as a native OIDC/OAuth2 provider rather than ForwardAuth. These services handle authentication natively and redirect users to Authentik's login flow.

| Service | Provider | Client ID | Redirect URI |
|---------|----------|-----------|-------------|
| Mealie | `mealie-oidc` (confidential) | `mealie` | `https://mealie.home.bstjohn.net/login` |
| Jellyfin | `jellyfin-oidc` (confidential) | `jellyfin` | `https://jellyfin.home.bstjohn.net/sso/OID/redirect/authentik` |
| Jellyseerr | `jellyseerr-oidc` (confidential) | `jellyseerr` | `https://jellyseerr.home.bstjohn.net/api/v1/auth/oidc-callback` |
| Seerr | `seerr-oidc` (confidential) | `seerr` | `https://seerr.home.bstjohn.net/login`, `https://seerr.home.bstjohn.net/profile/settings/linked-accounts`, regex `https://seerr\.home\.bstjohn\.net/users/\d+/settings/linked-accounts` |
| Headlamp | `headlamp-oidc` (confidential) | `headlamp` | `https://dashboard.home.bstjohn.net/oidc-callback` |
| Proxmox | `proxmox-oidc` (confidential) | `proxmox` | `https://proxmox.home.bstjohn.net`, `https://proxmox.ext.bstjohn.net` (no trailing slash) |
| Bin Scraper | `bin-scraper-oidc` (confidential) | `bin-scraper` | `https://bin-scraper.home.bstjohn.net/auth/callback` |
| Claws | `claws-oidc` (confidential) | `claws` | `https://claws.home.bstjohn.net/auth/callback`, `https://claws.ext.bstjohn.net/auth/callback` |
| Forgejo | `forgejo-oidc` (confidential) | `forgejo` | `https://git.home.bstjohn.net/user/oauth2/authentik/callback` |
| Home Assistant | `home-assistant-oidc` (confidential) | `home-assistant` | `https://home-assistant.home.bstjohn.net/auth/oidc/callback` |
| Container Registry | `registry-oidc` (confidential) | `registry` | `https://registry.home.bstjohn.net/zot/auth/callback/oidc` |
| Garden | `garden-oidc` (confidential) | `garden` | `https://garden.home.bstjohn.net/auth/callback` |

Garden gates every write in-app via `requireWriteAccess`, `/api/health` stays open for the kubelet and Gatus probes, and the ingress deliberately carries no `authentik-auth` middleware — ForwardAuth would put a redirect in front of the `Authorization: Bearer` path and is ruled out by Garden's `docs/ARCHITECTURE.md`. `OIDC_ALLOWED_GROUPS` is left empty on purpose because Garden requests only `openid profile email`, so no `groups` claim is present to check.

The OIDC configuration URL for Mealie is `https://auth.home.bstjohn.net/application/o/mealie/.well-known/openid-configuration`. Client secrets are stored in `authentik-secrets` and injected via `!Env` in the blueprint. Old proxy providers for these services are set `state: absent` in the blueprint (cleanup entries).

Each provider uses:
- `mode: forward_single` — single-host ForwardAuth (one provider per external URL)
- `authorization_flow: default-provider-authorization-implicit-consent` — auto-approves access (no consent screen)
- `invalidation_flow: default-provider-invalidation-flow` — required since Authentik 2026.2; controls session invalidation behavior

Each application references its provider via `!KeyOf`. All applications use `policy_engine_mode: any` — a user needs to match **any one** bound group policy to gain access.

### Headlamp: OIDC all the way to the kube-apiserver (#1024)

Headlamp is the only OIDC service whose ID token is validated by something other than the app itself: its backend forwards the token to the Kubernetes API server. That means the Authentik provider and the k3s API server share one client (`headlamp`, issuer `https://auth.home.bstjohn.net/application/o/headlamp/`), and changing the provider's `client_id`, its signing key, or the issuer URL breaks cluster login until the matching `oidc-*` kube-apiserver flags on the `k3s` node are updated too. `access_token_validity: "hours=24"` is deliberate — the ID token is re-validated on every API call. Group membership is what grants access twice over: the `infra` policy binding lets the user obtain a token at all, and the `oidc:infra` ClusterRoleBinding grants read-only Kubernetes RBAC.

### Session Duration (how often you re-login)

The SSO session length is set declaratively on the `default-authentication-login` user-login stage in `configmap-blueprints.yaml`:

- `session_duration: "days=30"` — overrides Authentik's shipped default of `seconds=0` (a browser-session cookie with a short server-side lifetime). A persistent 30-day session survives browser restarts, so app re-authentication stays transparent (no password prompt) for 30 days. This applies to **all** Authentik-protected apps.
- `remember_me_offset: "days=60"` — extends the session further when a user ticks "stay signed in" at login.

The Claws OIDC provider (`claws-oidc`) additionally pins longer token lifetimes so it bounces back to Authentik less often: `access_token_validity: "hours=24"` (was the 1-hour default) and `refresh_token_validity: "days=90"`. These are the levers to adjust if login frequency needs tuning.

Claws is the only OIDC client here that picks its Authentik host per request: `CLAWS_OIDC_HOST_MAP` maps an `.ext.` dashboard host to `https://auth.ext.bstjohn.net` so `.ext.` logins never bounce through the internal-only `auth.home.bstjohn.net` (claws#2841). Since the #1302 cutover it is set in one place: the StatefulSet (`clusters/my-cluster/claws/statefulset.yaml`) carries `claws.ext.bstjohn.net=…`. openclaw's `~/.claws/env` copy of the map (`claws.ext.bstjohn.net=…`, added 2026-09-04) is now inert because that host is powered off. Both callbacks above stay registered `matching_mode: strict`. There used to be a second `claws-staging.home`/`claws-staging.ext` pair, kept for a rollback to the openclaw tier; #1427 deleted it — the `claws-staging.*` Ingress went away at the #1302 cutover, so those callbacks were unreachable.

The other 11 native-OIDC apps have no per-request host map and each embeds a fixed `auth.home.bstjohn.net` issuer. Tailscale split DNS (`apps/tailnet-dns`, #1131) now resolves and connects that host from any tailnet device, so `.ext.` logins that bounce through `auth.home` complete off-LAN without the subnet router — except on encrypted-DNS clients, which still depend on the subnet router (see [infrastructure-overview.md](infrastructure-overview.md#remote-access-over-tailscale)). Claws' `CLAWS_OIDC_HOST_MAP` stays as-is; it is unaffected and remains the cleaner path where it applies.

### Groups and Access Control

Four groups provide role-based access control for people; two more, `claws-reader` and `claws-admin`, each hold only the matching Claws service account (see "Claws service accounts" below). Most applications are bound to a specific category group (order 0) plus the `all-apps` fallback group (order 1) — matching either grants access under `policy_engine_mode: any`.

| Group | Purpose | Applications |
|-------|---------|-------------|
| `all-apps` | Full access to all protected services | Bound to every ForwardAuth/OIDC application |
| `media` | Media automation services | Sonarr, Radarr, Prowlarr, Bazarr, Transmission, Jellyfin (OIDC), Jellyseerr (OIDC), Seerr (OIDC) |
| `home` | Home/lifestyle services | Mealie (OIDC), Bin Scraper (OIDC), Awtrix Kitchen, Awtrix Office, Garden (OIDC) |
| `infra` | Infrastructure admin tools | Grafana, Prometheus, Datasette, growth-engine, Headlamp (OIDC), Proxmox (OIDC), Claws (OIDC), Forgejo (OIDC) |

**Users** (declared in blueprint, group memberships are fully declarative):

| User | Groups | Notes |
|------|--------|-------|
| `brendan` | `all-apps`, `infra`, `authentik Admins` | Admin user; `all-apps` + `infra` are redundant while in Admins (superusers bypass policy checks) but kept as defense-in-depth |
| `eileen` | `media`, `home` | Restricted to media and home services only |
| `claws-reader` | `claws-reader` | Service account; Grafana/Prometheus only, Grafana Viewer (see "Claws service accounts") |
| `claws-admin` | `claws-admin` | Service account; Grafana/Prometheus only, Grafana Admin (see "Claws service accounts") |

**Important**: Group memberships in the blueprint are **fully declarative** — the `groups` attribute replaces all memberships on each blueprint reconciliation. Any manual group changes in the Authentik UI will be reverted. All group membership changes must go through `configmap-blueprints.yaml`.

### Adding a New Protected Service via Blueprint

Add four entries to `configmap-blueprints.yaml`: one provider, one application, and two policy binding entries (specific group + all-apps fallback):

```yaml
# Provider
- model: authentik_providers_proxy.proxyprovider
  id: myservice-provider-home
  identifiers:
    name: myservice-forward-auth-home
  state: present
  attrs:
    name: myservice-forward-auth-home
    mode: forward_single
    external_host: https://myservice.home.bstjohn.net
    authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
    invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]

# Application
- model: authentik_core.application
  id: myservice-app
  identifiers:
    slug: myservice
  state: present
  attrs:
    name: My Service
    slug: myservice
    provider: !KeyOf myservice-provider-home
    policy_engine_mode: any

# Policy bindings — replace group-CATEGORY with the appropriate group
- model: authentik_policies.policybinding
  identifiers:
    order: 0
    target: !KeyOf myservice-app
  state: present
  attrs:
    group: !KeyOf group-CATEGORY
    order: 0
    target: !KeyOf myservice-app
    enabled: true
    negate: false
    timeout: 30
- model: authentik_policies.policybinding
  identifiers:
    order: 1
    target: !KeyOf myservice-app
  state: present
  attrs:
    group: !KeyOf group-all-apps
    order: 1
    target: !KeyOf myservice-app
    enabled: true
    negate: false
    timeout: 30
```

Then add the `traefik.ingress.kubernetes.io/router.middlewares: default-authentik-auth@kubernetescrd` annotation to the service's Ingress.

## Traefik Middleware

Five Traefik `Middleware` CRDs work together as two chains — one per outpost — and four more form the Basic-auth-capable variant used only by Grafana and Prometheus (6–9 below):

1. **`authentik-strip-headers`** — Removes all `X-authentik-*` headers and `Authorization` from incoming requests before ForwardAuth processes them. Defense-in-depth against header forgery.

2. **`authentik-forwardauth`** — Sends a subrequest to Authentik at `http://authentik-server.default.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik`. On success, forwards `X-authentik-username`, `X-authentik-groups`, `X-authentik-email`, `X-authentik-name`, and `X-authentik-uid` headers to the backend (plus `X-authentik-grafana-role`, populated only for the two Grafana proxy providers — see "Grafana Integration" below).

   `trustForwardHeader` is deliberately `false`. Authentik's outpost selects which proxy application to evaluate from `X-Forwarded-Host`; with the flag on, Traefik would copy the client's value into the auth subrequest while still routing the real request by the `Host` header, letting a client pick a different application's policy bindings than the backend it reaches. With it off, Traefik derives `X-Forwarded-Host` from `req.Host` and `X-Forwarded-Uri` from the real request URI, which is exactly what the outpost needs. This is belt-and-braces: the `websecure` entrypoint (`forwardedHeaders.insecure: false`, no `trustedIPs` — pinned explicitly in `clusters/my-cluster/infrastructure/traefik/release.yaml`) already deletes all client-supplied `X-Forwarded-*` headers before routing.

3. **`authentik-auth`** — Chain middleware combining strip → forwardauth. This is what a service's `.home.` Ingress references.

4. **`authentik-forwardauth-ext`** — Identical to `authentik-forwardauth` (same `trustForwardHeader: false`, same response headers) but addressed at the standalone ext outpost: `http://authentik-proxy-ext.default.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik`.

5. **`authentik-auth-ext`** — Chain middleware combining strip → forwardauth-ext. Because `router.middlewares` is a per-Ingress annotation, a ForwardAuth service's ext host lives in its own `<svc>-ext` Ingress carrying `default-authentik-auth-ext@kubernetescrd` (Navidrome: a second route in its IngressRoute).

6. **`authentik-strip-authentik-headers`** — Like `authentik-strip-headers` but clears only the six `X-authentik-*` headers, leaving `Authorization` in place so an HTTP Basic app password reaches the outpost.

7. **`authentik-strip-authorization`** — Clears `Authorization` *after* ForwardAuth, so the backend never receives the app password (Grafana would otherwise try it as its own basic auth).

8. **`authentik-auth-basic`** / 9. **`authentik-auth-basic-ext`** — Chains strip-authentik-headers → forwardauth(-ext) → strip-authorization. Only the `grafana.{home,ext}` and `prometheus.{home,ext}` Ingresses use them, so the Claws service accounts can authenticate with Basic auth; every other host keeps `authentik-auth` / `authentik-auth-ext`. The outpost validates a Basic credential against Authentik (`intercept_header_auth`, the proxy-provider default) and then evaluates the application's policy bindings as for a browser session. A wrong or missing credential gets the usual 302 to the login page, not a 401.

### Applying to a Service

Add this annotation to any Ingress:

```yaml
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: default-authentik-auth@kubernetescrd
```

The `default-` prefix is the namespace where the middleware lives.

## Protected Services

### ForwardAuth (Traefik middleware)

| Service | SSO Behavior |
|---------|-------------|
| Sonarr, Radarr, Prowlarr, Bazarr | ForwardAuth gates access |
| Transmission | ForwardAuth gates access |
| Grafana | ForwardAuth + `auth.proxy` trusts `X-authentik-username`; local admin login kept as fallback |
| Prometheus | ForwardAuth gates access |
| Homepage | ForwardAuth gates access on `home.bstjohn.net`; bound to the `home` + `all-apps` groups. Behind the ingress, `homepage-router` (nginx) reads the `X-authentik-groups` header and serves the full dashboard to members of `infra` and a trimmed Apps-only dashboard to everyone else (#1079). Homepage itself has no per-user support. |
| Navidrome | ForwardAuth on the UI only; `/rest`, `/share`, `/ping` bypass it via priority-100 routes on the same IngressRoute so Subsonic clients work. `ND_EXTAUTH_*` trusts `X-authentik-username` from the pod CIDR, backed by a NetworkPolicy. |
| Music Assistant | ForwardAuth gates `music-assistant.home.bstjohn.net`. The add-on itself is host-networked on 192.168.0.89 and answers `http://192.168.0.89:8095` unauthenticated on the LAN; the proxy cannot prevent that, same as the Awtrix clocks. |
| growth-engine | ForwardAuth gates access on both `growth-engine.home.bstjohn.net` and `growth-engine.ext.bstjohn.net`; bound to the `infra` group. |
| Pages | ForwardAuth gates `pages.home.bstjohn.net` (home only); bound to the `infra` + `all-apps` groups. The S3 API host `s3.home.bstjohn.net` has no ForwardAuth — SigV4 is its auth. See [pages.md](pages.md). |

### Native OIDC Integration

| Service | SSO Behavior |
|---------|-------------|
| Mealie | OIDC via Authentik; `OIDC_AUTH_ENABLED=true`, `OIDC_AUTO_REDIRECT=false`. No ingress annotation needed. Mealie v3.21.0+ requires `email_verified=true` on the ID token/userinfo response (`OIDC_REQUIRES_EMAIL_VERIFICATION` left at its default `true`); `mealie-oidc-provider` uses `email-verified-scope-mapping` (see above) instead of Authentik's built-in `email` mapping to supply it. A user added to the blueprint without `attributes.email_verified: true` is rejected by Mealie with "email_verified claim is missing or false". |
| Jellyfin | OIDC via `jellyfin-plugin-sso` 3.5.2.4 (plugin binary is a manual install; its OID config, `SchemeOverride`, the login-page button and the plugin repository are reconciled by the `config-reconciler` sidecar in `apps/jellyfin/deployment.yaml`, see #817); callback at `/sso/OID/redirect/authentik`. No ingress annotation needed. |
| Jellyseerr | OIDC via Authentik (configured via Jellyseerr Settings → Users); callback at `/api/v1/auth/oidc-callback`. No ingress annotation needed. |
| Seerr | OIDC via Authentik, provider `seerr-oidc`; preview image `ghcr.io/seerr-team/seerr:preview-new-oidc` (upstream PR #2715, unreleased) has no UI for OIDC, so the provider is written into `settings.json` by the `oidc-init` initContainer in `apps/seerr/deployment.yaml`. No ingress annotation needed. |
| Headlamp | OIDC via Authentik; callback at `/oidc-callback`. Access restricted to the infra group; the ID token is also validated by the kube-apiserver (see below). |
| Proxmox | OIDC via Authentik realm `authentik`; callback is the bare origin (no trailing slash). Realm configured manually on Proxmox host (not GitOps). Access restricted to `infra` group. |
| Bin Scraper | OIDC via Authentik; callback at `/auth/callback`. Access restricted to `home` group. Client env (`OIDC_ISSUER`/`OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET`/`OIDC_REDIRECT_URI`) lives in `apps/bin-scraper/deployment.yaml`; issuer URL requires its trailing slash. |
| Claws | OIDC via Authentik; callback at `/auth/callback`. Bearer-token API access (webhooks) still works in OIDC mode. Access restricted to `infra` group. Since the #1302 cutover, `claws.home.bstjohn.net`/`claws.ext.bstjohn.net` route to the in-cluster StatefulSet; there is no external backend. |
| Forgejo | OIDC via Authentik native OAuth2 auth source (`forgejo admin auth add-oauth`, created by migration 0019 — not declarable as YAML since Forgejo stores auth sources in its DB); callback at `/user/oauth2/authentik/callback`. Access restricted to `infra` group. Local password login remains as fallback; legacy OpenID 2.0 signin (`/user/login/openid`) disabled. |

### Jellyfin SSO

Jellyfin has no native OIDC support, so SSO is via the third-party `jellyfin-plugin-sso` plugin (GUID `505ce9d1d91642fa86ca673ef241d7df`). The plugin binary itself is a manual install — Dashboard → Plugins → Catalog → SSO-Auth → install → restart Jellyfin. The catalog repository (`https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/manifest-release/manifest.json`) is registered automatically by the `config-reconciler` sidecar (`apps/jellyfin/deployment.yaml` / `apps/jellyfin/reconciler-configmap.yaml`, #817), so it just needs to be selected from the catalog after install.

Once installed, the sidecar enforces the plugin's `authentik` OID provider config every 5 minutes: endpoint `https://auth.home.bstjohn.net/application/o/jellyfin/`, client id `jellyfin`, secret from `authentik-secrets` key `JELLYFIN_OIDC_CLIENT_SECRET`, `RoleClaim: groups`, `OidScopes: [groups]`, `Roles: [media, all-apps]`, `AdminRoles: []`, `EnableAllFolders: true`, plus the login-page "Sign in with Authentik" button (`LoginDisclaimer`). The reconciler merges into the existing provider config rather than replacing it, because the plugin also stores `CanonicalLinks` there — runtime state mapping Jellyfin usernames to user IDs, built by real logins. Replacing the object wholesale would re-link or duplicate accounts.

**Scheme gotcha**: the plugin derives its OIDC `redirect_uri` from `Request.Scheme`, which behind Traefik is `http` unless Jellyfin trusts the forwarded headers. Jellyfin's `KnownProxies` setting does not honour a CIDR entry, so trusting Traefik would require the *literal* Traefik pod IP — which changes on every reschedule — and Authentik's redirect-URI matching is strict, so a stale IP silently breaks login. Rather than chase that IP, the reconciler sets `SchemeOverride: "https"` on the provider config (available since plugin 3.5.2.0), which forces an `https://` redirect URI unconditionally. `KnownProxies` is consequently **not** load-bearing for SSO; the only cost of leaving it stale is that Jellyfin logs Traefik's pod IP as the client IP. If the plugin is ever upgraded, re-check that `SchemeOverride` still exists in `OidConfig` before relying on it.

### Seerr SSO

Jellyseerr 2.7.3 ships no OIDC code at all, so its `jellyseerr-oidc` provider is unused and stays in the blueprint only until `apps/jellyseerr/` is retired — at which point the four `jellyseerr-*` blocks are deleted with it. Its stale `/api/v1/auth/oidc-callback` redirect URI is harmless: nothing ever calls it.

OIDC instead arrives via **Seerr** (#820), the merged successor project, running *beside* Jellyseerr at `seerr.home.bstjohn.net` on its own `seerr-config` PVC. It is an **experimental preview** — the OIDC implementation is upstream PR `seerr-team/seerr#2715`, still open and in no stable release — so the image is pinned by digest (`ghcr.io/seerr-team/seerr:preview-new-oidc@sha256:6a2a160b…`); the tag is mutable and force-pushed, Renovate cannot track it, and bumps are manual. Read [discussion #2721](https://github.com/seerr-team/seerr/discussions/2721) before bumping — this tag has broken login outright before. Rollback is simply using Jellyseerr, which is never touched.

Seerr gets a fully independent Authentik identity — provider `seerr-oidc`, client id `seerr`, application slug `seerr`, secret `SEERR_OIDC_CLIENT_SECRET` (migration 0004) — rather than borrowing Jellyseerr's, so decommissioning either app is a clean deletion.

The preview build ships **no UI for OIDC**, so the provider is written into `/app/config/settings.json` by the `oidc-init` initContainer (`apps/seerr/oidc-init-configmap.yaml`): `main.oidcLogin: true`, plus an `oidc.providers` entry with slug `authentik`, issuer `https://auth.home.bstjohn.net/application/o/seerr/`, client id `seerr` and `newUserLogin: true`. Details that matter:

- **The issuer's trailing slash is load-bearing** — `openid-client` compares it verbatim against the discovery document and rejects a mismatch.
- **`localLogin` stays `true`** as the lockout fallback if this preview's OIDC path breaks.
- **initContainer, not a sidecar.** `Settings.save()` re-serialises the whole in-memory object over `settings.json`, so a live writer would be clobbered by any settings change made in the UI. `Settings.load()` does `mergeSettings(defaults, file)` with the file winning, so writing before start-up is authoritative — and any drift is repaired on the next pod restart.
- **First boot has no `settings.json`.** The script logs and skips; complete the setup wizard, then `kubectl rollout restart deploy/seerr` to apply OIDC. It never exits non-zero — a hard failure would wedge the pod in `Init:CrashLoopBackOff`.
- The initContainer also `chown`s `/app/config` to `1000:1000` (the image runs as `node`); `local-path` PVs get no kubelet `fsGroup`, so `fsGroup: 1000` would be a silent no-op.

Access control is the `media` + `all-apps` policy bindings on `seerr-app`, not `requiredClaims` in Seerr.

### Services NOT Protected (by design)

| Service | Reason |
|---------|--------|
| Authentik | Circular dependency — it IS the auth provider |
| Gatus | Intentionally excluded — monitoring must remain accessible during an Authentik outage to allow investigating service health. Gatus is read-only monitoring data. |
| Immich | Has its own auth; mobile apps need direct API access |
| Home Assistant | No ForwardAuth — IoT integrations and the Companion app need direct API access. Native OIDC SSO is available via the vendored `auth_oidc` component; HA's own login form stays enabled. Mobile sign-in uses a device code, not an in-app redirect. |
| Overseerr | Uses Plex auth natively; ForwardAuth would create a double-login |
| Plex | Has its own auth; streaming apps need direct access |
| NAS, UniFi | Have their own auth; infrastructure admin interfaces |

## Break-glass: reaching a service while Authentik is down

Authentik is a single point of failure for the 12 ForwardAuth services. This section is
the recovery path; it exists because the *arr apps have no login of their own to fall
back to (`AuthenticationMethod: External`, see [servarr.md](servarr.md)).

### Triage order

1. **Gatus** (`gatus.home.bstjohn.net`) is deliberately outside ForwardAuth and stays
   reachable. Check its three Authentik endpoints: `Authentik`
   (`http://authentik-server:9000/-/health/live/`), `Authentik Worker`, and
   `Authentik Ext Outpost`.
2. If the **server** is down, this section applies — use port-forward below.
3. If only the **worker** is unhealthy, or logins work but a newly merged blueprint 404s,
   it is the wedge described in [Worker](#worker): `kubectl rollout restart
   deployment/authentik-worker`. Logins keep working; nothing here is needed.
4. If both are down, check Postgres — Authentik 2026.2 keeps cache, channel layer and
   sessions in Postgres, so a `postgres` outage takes all of Authentik with it.

### Reaching a service in the meantime

`kubectl port-forward` reaches the pod through the kubelet, not the pod network, so it
bypasses **both** ForwardAuth (which lives on the Traefik ingress only) and the
NetworkPolicies that restrict each app's ClusterIP to named peers. It is the only
intended emergency access path.

| Service | Command | Then open |
|---------|---------|-----------|
| Sonarr | `kubectl port-forward svc/sonarr 8989:8989` | `http://localhost:8989` |
| Radarr | `kubectl port-forward svc/radarr 7878:7878` | `http://localhost:7878` |
| Prowlarr | `kubectl port-forward svc/prowlarr 9696:9696` | `http://localhost:9696` |
| Bazarr | `kubectl port-forward svc/bazarr 6767:6767` | `http://localhost:6767` |
| Transmission | `kubectl port-forward svc/transmission 9091:9091` | `http://localhost:9091/transmission/web/` |
| Prometheus | `kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090` | `http://localhost:9090` |
| Homepage | `kubectl port-forward svc/homepage 3000:3000` | `http://localhost:3000` |
| Navidrome | `kubectl port-forward svc/navidrome 4533:4533` | `http://localhost:4533` |

Port-forwarded *arr apps come up unauthenticated — `AuthenticationRequired:
DisabledForLocalAddresses` suppresses the login prompt for local addresses. Treat the
forward as a privileged shell: it is equivalent to admin on that app.

**Do not** remove the `traefik.ingress.kubernetes.io/router.middlewares` annotation from an
ingress to get back in. It is the only authentication those services have, it must go
through a PR to `main` to take effect anyway, and it leaves the service open until a second
PR restores it.

### Services that keep a non-Authentik login

These need no break-glass step — sign in with the local account instead:

| Service | Fallback |
|---------|----------|
| Grafana | Local admin login form stays enabled |
| Forgejo | Local password login retained alongside the OIDC auth source |
| Seerr | `localLogin: true` in `settings.json`, kept precisely as the lockout fallback |
| Jellyfin, Jellyseerr | Native Jellyfin accounts; the SSO plugin is additive |
| Home Assistant | Own login form; OIDC is additive |
| Immich, Plex, Overseerr | Own auth, never behind ForwardAuth |
| Proxmox, NAS, UniFi | Own auth (Proxmox keeps its local PAM realm beside the `authentik` realm) |
| Gatus | No auth, deliberately outside ForwardAuth |

Three ForwardAuth services stay reachable on the LAN regardless: **Music Assistant**
(`http://192.168.0.89:8095`) and the two **Awtrix** clocks are LAN devices the proxy only
fronts, never runs. **Navidrome**'s `/rest`, `/share` and `/ping` routes bypass ForwardAuth
at `priority: 100`, so Subsonic clients are unaffected by an Authentik outage — only the
web UI is.

## Grafana Integration

Grafana uses `auth.proxy` for deeper SSO integration beyond ForwardAuth:

```yaml
auth.proxy:
  enabled: true
  header_name: X-authentik-username
  header_property: username
  auto_sign_up: true
  headers: "Name:X-authentik-name Email:X-authentik-email Role:X-authentik-grafana-role"
  # Pod-network whitelist is gated by NetworkPolicy (grafana-networkpolicy.yaml) — only Traefik pods can reach :3000.
  whitelist: "10.42.0.0/16"
```

Grafana maps incoming `X-authentik-username` headers to user accounts. `auto_sign_up: true` creates the Grafana user on first proxy login, which is how the `claws-reader` / `claws-admin` service accounts get Grafana users without a migration. This is safe because only Traefik pods reach :3000, the outpost is the only source of `X-authentik-*` headers, and the org role is re-synced from the header on every login. The local admin login form remains enabled as a fallback.

The `Role:` entry derives Grafana's org role from Authentik group membership rather than whatever was last set by hand in Grafana's database. `grafana-role-scope-mapping` (in `configmap-blueprints.yaml`, attached to `grafana-provider-home`, `grafana-provider-ext` and `grafana-provider-prod`) emits `X-authentik-grafana-role: Admin` for members of the `infra`, `authentik Admins` or `claws-admin` groups, and `Viewer` for everyone else. Grafana's `auth.proxy` reads this with `SyncOrgRoles: true`, so the role is re-applied on **every** proxy login — it survives a Grafana PVC rebuild and a stale hand-set role cannot persist past the next sign-in. This only takes effect on a fresh login: an already-established outpost session carries claims minted before the mapping existed (or before a group change), so a user must log out of the application and back in — or wait for the session to expire — before their role updates. Grafana hides **Explore** from the Viewer role, so querying the `loki` datasource (see `docs/logging.md`) requires Editor or Admin. The header is only ever set by the Grafana proxy providers — no other app's ForwardAuth response carries it — and any client-supplied copy is cleared by `authentik-strip-authentik-headers` (in the `authentik-auth-basic` chains) before ForwardAuth runs, then only re-added if listed in `authResponseHeaders` on `authentik-forwardauth` / `authentik-forwardauth-ext`.

**Defense-in-depth for header spoofing**: A NetworkPolicy (`apps/monitoring/grafana-networkpolicy.yaml`) restricts Grafana's ingress on port 3000 to pods in the `traefik` namespace, plus the Gatus health check and Prometheus's self-monitoring scrape — no other in-cluster pod can reach Grafana directly to forge `X-authentik-*` headers. Claws is deliberately **not** admitted: it reaches Grafana through Traefik like a browser, authenticating as an Authentik service account (see "Claws service accounts"), so its identity headers come from the outpost too. The `whitelist: 10.42.0.0/16` is a secondary safeguard; with the NetworkPolicy enforcing source restriction, it serves as belt-and-suspenders rather than the primary control.

## Claws service accounts

Claws queries Grafana (datasource proxy for Prometheus and Loki, alert state) and Prometheus through
their normal Traefik hostnames, as two Authentik users declared in `configmap-blueprints.yaml`.
They mirror the Forgejo `claws-reader` / `claws-admin` split in [forgejo.md](forgejo.md#claws-bot-accounts):

- **`claws-reader`** — group **`claws-reader`**. Grafana role Viewer (the role mapping's default).
- **`claws-admin`** — group **`claws-admin`**. Grafana role Admin, via `grafana-role-scope-mapping`.

Both are `type: service_account` users under the `service-accounts` path, and each is the only
member of its group. The groups are bound to `grafana`, `grafana-ext`, `prometheus` and
`prometheus-ext` (orders 2 and 3, after `infra` and `all-apps`) and to `grafana-prod` (orders 1
and 2), and to nothing else.

Each account has one non-expiring **app password** (`authentik_core.token`, `intent: app_password`,
identifiers `claws-reader-app-password` / `claws-admin-app-password`) whose key the blueprint pins
from `authentik-secrets` via `!Env`:

| Key in `authentik-secrets` | Account | Claws env |
|---|---|---|
| `CLAWS_READER_APP_PASSWORD` | `claws-reader` | `CLAWS_AUTHENTIK_READER_PASSWORD` (username in `CLAWS_AUTHENTIK_READER_USERNAME`) |
| `CLAWS_ADMIN_APP_PASSWORD` | `claws-admin` | `CLAWS_AUTHENTIK_ADMIN_PASSWORD` (username in `CLAWS_AUTHENTIK_ADMIN_USERNAME`) |

Migration 0004 generates the keys. `clusters/my-cluster/claws/statefulset.yaml` reads them straight
from `authentik-secrets` with `optional: true`, because the `claws` Flux Kustomization does not
depend on `migrations`; migration 0040 restarts the `claws` StatefulSet once both keys exist.
Changing any of these variable names needs both repos updated.

Claws sends the pair as HTTP Basic auth. The `authentik-auth-basic(-ext)` chains (see "Traefik
Middleware") let `Authorization` reach the outpost, which validates it and returns the usual
`X-authentik-*` headers; Grafana's `auth.proxy` then signs the account in (`auto_sign_up: true`)
with the role from `X-authentik-grafana-role`. The Grafana NetworkPolicy does not admit Claws
pods, and there are no Grafana-minted service-account tokens.

**Rotation:** delete the key from `authentik-secrets`. Migration 0004 regenerates it on its next
run, the worker re-applies the blueprint once restarted (it reads `!Env` at start), and a Claws
restart picks up the new value.

## Prod Grafana outpost

The prod cluster's Grafana (`https://grafana.bstjohn.net`, St-John-Software/production-infra) is
gated by an Authentik proxy outpost that runs **inside the prod cluster** but is configured here.
This blueprint declares:

- `grafana-provider-prod` (`forward_single`, public-dashboard paths and `^/api/health$` skipped,
  `grafana-role-scope-mapping` attached) and the `grafana-prod` application, bound to `infra`,
  `claws-reader` and `claws-admin` only (no `all-apps`).
- `prod-proxy-outpost` (`authentik_host` and `authentik_host_browser` both
  `https://auth.ext.bstjohn.net`, reached over the tailnet), identified by name only like
  `ext-proxy-outpost`.
- `prod-proxy-outpost-token`, pinning the outpost's `ak-outpost-<uuid>-api` token key to
  `authentik-secrets/PROD_OUTPOST_TOKEN` (generated by migration 0004).

production-infra owns the outpost Deployment, its Traefik middlewares and the SOPS Secret holding
its token. Keep its proxy image in step with the fleet's `authentik-proxy-ext`
(`ghcr.io/goauthentik/proxy:2026.8.3` at the time of writing); the production-infra issue's
2026.2.1 is stale.

**Manual action (once, and after any rotation):** copy the `PROD_OUTPOST_TOKEN` value from
`authentik-secrets` in this cluster into production-infra's SOPS-encrypted outpost Secret. Pipe it
from `kubectl get secret authentik-secrets -o jsonpath="{.data['PROD_OUTPOST_TOKEN']}" | base64 -d`
into the SOPS edit; never put it on a command line or paste it in chat.

## Security Model

| Attack Vector | Risk | Mitigation |
|---------------|------|------------|
| External (through Traefik) | None — Traefik overwrites headers | Strip-headers middleware (defense-in-depth) |
| Internal (bypasses Traefik) | None — only Traefik pods can reach Grafana port 3000 | NetworkPolicy `grafana-ingress-from-traefik-only`; secondary: `auth.proxy.whitelist: 10.42.0.0/16` |
| Forged `X-Forwarded-Host` (application confusion) | None — entrypoint deletes client `X-Forwarded-*`; ForwardAuth re-derives from `req.Host` | `forwardedHeaders.insecure: false` + no `trustedIPs` on the `web`/`websecure` entrypoints; `trustForwardHeader: false` on `authentik-forwardauth` |
| Forged `X-authentik-grafana-role` (Grafana org-role escalation) | None — client-supplied header is cleared before ForwardAuth runs; only Traefik pods can reach Grafana | `authentik-strip-authentik-headers` `customRequestHeaders` + `grafana-ingress-from-traefik-only` NetworkPolicy |
| Client `Authorization` on Grafana/Prometheus hosts | None — it reaches only the outpost, which validates it against Authentik as an app password; it is cleared before the backend | `authentik-auth-basic(-ext)`: strip `X-authentik-*` → ForwardAuth → `authentik-strip-authorization`. `X-authentik-*` spoofing stays impossible because those headers are still cleared first and re-added only from `authResponseHeaders` |

The header-stripping middleware is defense-in-depth: even if Traefik had a bug or partial auth-service failure, client-supplied `X-authentik-*` headers are cleared before ForwardAuth runs. `Authorization` is also cleared before ForwardAuth on every host except the four Grafana/Prometheus hosts, where it must reach the outpost so the Claws service accounts can authenticate with Basic auth; there it is cleared after ForwardAuth instead, so the backend still never sees it.

## Secrets

All secrets live in the `authentik-secrets` Secret in the `default` namespace.

| Key | Used By | Source |
|-----|---------|--------|
| `AUTHENTIK_SECRET_KEY` | server, worker | Auto-generated by migration job 0001 |
| `AUTHENTIK_BOOTSTRAP_TOKEN` | server | Auto-generated by migration job 0002 |
| `PG_PASS` | server, worker | Auto-generated by migration job 0003; set as the `authentik` role's password on the shared `postgres` instance by migration job 0025 |
| `MEALIE_OIDC_CLIENT_SECRET` | mealie | Auto-generated by migration job 0004 |
| `JELLYFIN_OIDC_CLIENT_SECRET` | authentik-worker (blueprint) + jellyfin `config-reconciler` sidecar | Auto-generated by migration job 0004 |
| `JELLYSEERR_OIDC_CLIENT_SECRET` | authentik-worker (injected into blueprint) | Auto-generated by migration job 0004 |
| `SEERR_OIDC_CLIENT_SECRET` | authentik-worker (blueprint) + seerr `oidc-init` initContainer | Auto-generated by migration job 0004 |
| `HEADLAMP_OIDC_CLIENT_SECRET` | authentik-worker (injected into blueprint), headlamp-oidc secret | Auto-generated by migration job 0004 |
| `PROXMOX_OIDC_CLIENT_SECRET` | authentik-worker (injected into blueprint) | Auto-generated by migration job 0004 |
| `BIN_SCRAPER_OIDC_CLIENT_SECRET` | authentik-worker (blueprint) + bin-scraper Deployment (`OIDC_CLIENT_SECRET`) | Auto-generated by migration job 0004 |
| `CLAWS_OIDC_CLIENT_SECRET` | authentik-worker (injected into blueprint) + claws | Auto-generated by migration job 0004 |
| `FORGEJO_OIDC_CLIENT_SECRET` | authentik-worker (injected into blueprint) | Auto-generated by migration job 0004 |
| `HOME_ASSISTANT_OIDC_CLIENT_SECRET` | authentik-worker (blueprint) | Auto-generated by migration job 0004 |
| `GARDEN_OIDC_CLIENT_SECRET` | authentik-worker (blueprint) + garden Deployment (`OIDC_CLIENT_SECRET`) | Auto-generated by migration job 0004 |
| `EXT_OUTPOST_TOKEN` | authentik-worker (blueprint) + `authentik-proxy-ext` | Auto-generated by migration job 0004 |
| `PROD_OUTPOST_TOKEN` | authentik-worker (blueprint); copied by hand to production-infra | Auto-generated by migration job 0004 |
| `CLAWS_READER_APP_PASSWORD` | authentik-worker (blueprint) + claws (`CLAWS_AUTHENTIK_READER_PASSWORD`) | Auto-generated by migration job 0004 |
| `CLAWS_ADMIN_APP_PASSWORD` | authentik-worker (blueprint) + claws (`CLAWS_AUTHENTIK_ADMIN_PASSWORD`) | Auto-generated by migration job 0004 |
| `AUTHENTIK_BOOTSTRAP_PASSWORD` | server | **Manually provided** — initial `akadmin` password |

The `migrations/` Jobs (repo root, see [apps-overview.md](apps-overview.md#secret-migration-jobs)) auto-generate all keys except `AUTHENTIK_BOOTSTRAP_PASSWORD`. On initial cluster setup, only the bootstrap password requires manual creation:

```bash
kubectl create secret generic authentik-secrets \
  --from-literal=AUTHENTIK_BOOTSTRAP_PASSWORD="<chosen-admin-password>" \
  -n default
```

Once the secret exists, Flux deploys the migration jobs which patch in the remaining keys. The migration jobs are idempotent — they check if the key already exists before generating and patching. See [apps-overview.md](apps-overview.md#secret-migration-jobs) for full migration job documentation.

**Important**: Do **not** define the `authentik-secrets` Secret in any Kustomize manifest. Flux SSA would reset the `.data` field on every reconcile, wiping all populated keys. The secret must be created imperatively and left unmanaged by Flux.

To retrieve a generated value after setup:
```bash
kubectl get secret authentik-secrets -n default \
  -o jsonpath='{.data.AUTHENTIK_SECRET_KEY}' | base64 -d
```

## Domain

- **URL**: `auth.home.bstjohn.net`

## Proxmox Realm Setup (Manual)

After Flux reconciles and migration job 0004 completes, configure the Proxmox realm manually on any Proxmox host node.

Retrieve the client secret:
```bash
kubectl get secret authentik-secrets -n default \
  -o jsonpath='{.data.PROXMOX_OIDC_CLIENT_SECRET}' | base64 -d
```

Add the realm (replace `<secret>` with the value above):
```bash
pveum realm add authentik --type openid \
  --issuer-url https://auth.home.bstjohn.net/application/o/proxmox/ \
  --client-id proxmox \
  --client-key <secret> \
  --username-claim preferred_username \
  --autocreate 1 \
  --default 0
```

Notes:
- The issuer URL **must end with a trailing slash** — Proxmox appends `.well-known/openid-configuration` to construct the discovery URL.
- The redirect URIs, by contrast, must **not** end with a slash: the Proxmox login page sends `location.origin` (e.g. `https://proxmox.home.bstjohn.net`) as `redirect_uri`, and the provider's strict matching rejects `https://proxmox.home.bstjohn.net/` with "Redirect URI Error" (#1149).
- Authenticated users get zero Proxmox privileges until an operator grants them: `pveum aclmod / -user <username>@authentik -role PVEAdmin` (or a less-privileged role).
- Users sign in by selecting realm `authentik` on the Proxmox login screen.
