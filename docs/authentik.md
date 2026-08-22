# Authentik SSO

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
├── deployment-postgresql.yaml      # PostgreSQL 16
├── service-server.yaml             # Server: port 9000, 9300 (metrics)
├── service-postgresql.yaml         # PostgreSQL: port 5432
├── ingress.yaml                    # auth.home.bstjohn.net
├── pvc-postgresql.yaml             # 5 Gi local-path
├── middleware-strip-headers.yaml   # Traefik: clear auth headers from client
├── middleware-forwardauth.yaml     # Traefik: ForwardAuth to Authentik
├── middleware-chain.yaml           # Traefik: strip → forwardauth chain
├── networkpolicy-postgresql.yaml   # Restricts port 5432 to server + worker pods
└── configmap-blueprints.yaml       # Declarative provider + application config
```

### Server

| Setting | Value |
|---------|-------|
| Image | `ghcr.io/goauthentik/server:2026.2.1` |
| Ports | 9000 (HTTP), 9443 (HTTPS), 9300 (Prometheus metrics) |
| CPU | 100m request, 1000m limit |
| Memory | 512 MB request, 1536 MB limit |
| `/dev/shm` | `emptyDir{medium: Memory}`, 256Mi |
| Priority | `critical-infrastructure` |
| Strategy | Recreate |
| Liveness | HTTP GET `/-/health/live/` port 9000 |
| Readiness | HTTP GET `/-/health/ready/` port 9000 |

Uses an embedded outpost — no separate outpost deployment needed. The ForwardAuth endpoint is `http://authentik-server.default.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik` (FQDN required because the ForwardAuth middleware is resolved by Traefik, which runs in the `traefik` namespace and cannot resolve short service names in `default`). Both server and worker mount the blueprints ConfigMap at `/blueprints/custom`.

**`/dev/shm` sizing**: gunicorn's tmpfs-backed shared memory (worker heartbeat/temp files) needs more than the containerd default 64Mi — an undersized `/dev/shm` causes the kernel to deliver **SIGBUS** to the gunicorn worker on an `mmap` page fault, crashlooping the pod (`signal: bus error` immediately after "applying django migrations", while PostgreSQL connections keep succeeding). The fix is a dedicated `dshm` `emptyDir{medium: Memory, sizeLimit: 256Mi}` volume mounted at `/dev/shm`. Because tmpfs usage counts against the container's memory cgroup, `limits.memory` was raised from 1Gi to 1536Mi alongside it — adding the shm volume without the limit increase can re-trigger the same SIGBUS under memory pressure.

### Worker

| Setting | Value |
|---------|-------|
| Image | `ghcr.io/goauthentik/server:2026.2.1` (same image, `worker` arg) |
| CPU | 50m request, 500m limit |
| Memory | 512 MB request, 1 GB limit |
| Priority | `standard` |
| Liveness | exec `ak healthcheck` (30s initial, 30s period) |
| Readiness | exec `ak healthcheck` (30s initial, 10s period) |

Handles async tasks (email, background jobs, blueprint processing). Shares the same database connection as the server. The readiness probe uses the same `ak healthcheck` command as liveness but checks more frequently (10s vs 30s), enabling faster detection of transient issues like database disconnects.

### PostgreSQL

| Setting | Value |
|---------|-------|
| Image | `postgres:16.13-alpine` |
| Port | 5432 |
| Storage | 5 Gi, local-path (`authentik-postgresql-data`) |
| CPU | 50m request, 1000m limit |
| Memory | 128 MB request, 256 MB limit |
| Priority | `critical-infrastructure` |
| Termination grace | 90s (WAL flush + checkpoint) |

Authentik 2026.2 has no Redis dependency: cache uses `django_postgres_cache`, the channel layer uses `django_channels_postgres`, and sessions are DB-backed (`authentik.core.sessions`) — all Postgres. A previously deployed `authentik-redis` (Redis 7, `AUTHENTIK_REDIS__HOST` env var on server/worker) was leftover from an older Authentik version; before removal it showed 0 keys and only 3 commands processed (the diagnostic session itself) over 136 days of uptime, confirming it was unused. It was removed in #828 along with its unauthenticated, cluster-reachable port 6379. Do not re-add Redis — if a rollback to an Authentik version older than ~2025.2 is ever needed, the manifests are recoverable from this commit's git history.

**NetworkPolicy**: `networkpolicy-postgresql.yaml` restricts ingress on port 5432 to pods labeled `app: authentik-server` or `app: authentik-worker`, the same pattern as the Grafana/Prometheus NetworkPolicies in `apps/monitoring/`. This closes off the other 30+ pods in `default` from reaching Postgres directly — it holds session, cache, channel-layer and task state for the SSO system fronting every protected service.

## Blueprints (Declarative Configuration)

Authentik applications and proxy providers are configured declaratively via blueprints in `configmap-blueprints.yaml`. The ConfigMap is mounted into both the server and worker at `/blueprints/custom`. Authentik auto-discovers and applies blueprints on startup and periodically thereafter.

The blueprint defines:
- **8 ForwardAuth proxy providers** (8 services, home domain only) + **8 proxy applications**, managed via the embedded outpost
- **11 OIDC providers** (Mealie, Open WebUI, Jellyfin, Jellyseerr, Seerr, Headlamp, Proxmox, Bin Scraper, Claws, Forgejo, Home Assistant) + **11 OIDC applications**, using native OAuth2/OIDC integration
- **4 groups**, **2 users**, and **16 ForwardAuth policy bindings** (8 services × 2 bindings each)

The **embedded outpost** is declaratively configured in the blueprint via an `authentik_outposts.outpost` entry that lists all 8 proxy providers by `!KeyOf` reference. This ensures provider-to-outpost attachment is version-controlled and reproducible. Critical invariant: every `!KeyOf` reference in the outpost's `providers` list must point to a provider with `state: present` — referencing an absent provider causes the entire outpost entry to fail to apply.

### ForwardAuth Proxy Providers

| Service | Provider | Application Slug |
|---------|----------|-----------------|
| Sonarr | `sonarr-forward-auth-home` | `sonarr` |
| Radarr | `radarr-forward-auth-home` | `radarr` |
| Prowlarr | `prowlarr-forward-auth-home` | `prowlarr` |
| Bazarr | `bazarr-forward-auth-home` | `bazarr` |
| Transmission | `transmission-forward-auth-home` | `transmission` |
| Grafana | `grafana-forward-auth-home` | `grafana` |
| Prometheus | `prometheus-forward-auth-home` | `prometheus` |
| Datasette | `datasette-forward-auth-home` | `datasette` |

### OIDC Providers

Several services use Authentik as a native OIDC/OAuth2 provider rather than ForwardAuth. These services handle authentication natively and redirect users to Authentik's login flow.

| Service | Provider | Client ID | Redirect URI |
|---------|----------|-----------|-------------|
| Mealie | `mealie-oidc` (confidential) | `mealie` | `https://mealie.home.bstjohn.net/login` |
| Open WebUI | `open-webui-oidc` (confidential) | `open-webui` | `https://chat.home.bstjohn.net/oauth/oidc/callback` |
| Jellyfin | `jellyfin-oidc` (confidential) | `jellyfin` | `https://jellyfin.home.bstjohn.net/sso/OID/redirect/authentik` |
| Jellyseerr | `jellyseerr-oidc` (confidential) | `jellyseerr` | `https://jellyseerr.home.bstjohn.net/api/v1/auth/oidc-callback` |
| Seerr | `seerr-oidc` (confidential) | `seerr` | `https://seerr.home.bstjohn.net/login`, `https://seerr.home.bstjohn.net/profile/settings/linked-accounts`, regex `https://seerr\.home\.bstjohn\.net/users/\d+/settings/linked-accounts` |
| Headlamp | `headlamp-oidc` (confidential) | `headlamp` | `https://dashboard.home.bstjohn.net/oidc-callback` |
| Proxmox | `proxmox-oidc` (confidential) | `proxmox` | `https://proxmox.home.bstjohn.net/` |
| Bin Scraper | `bin-scraper-oidc` (confidential) | `bin-scraper` | `https://bin-scraper.home.bstjohn.net/auth/callback` |
| Claws | `claws-oidc` (confidential) | `claws` | `https://claws-staging.home.bstjohn.net/auth/callback`, `https://claws.home.bstjohn.net/auth/callback` |
| Forgejo | `forgejo-oidc` (confidential) | `forgejo` | `https://git.home.bstjohn.net/user/oauth2/authentik/callback` |
| Home Assistant | `home-assistant-oidc` (confidential) | `home-assistant` | `https://home-assistant.home.bstjohn.net/auth/oidc/callback` |

The OIDC configuration URL for Mealie is `https://auth.home.bstjohn.net/application/o/mealie/.well-known/openid-configuration`. Client secrets are stored in `authentik-secrets` and injected via `!Env` in the blueprint. Old proxy providers for these services are set `state: absent` in the blueprint (cleanup entries).

Each provider uses:
- `mode: forward_single` — single-host ForwardAuth (one provider per external URL)
- `authorization_flow: default-provider-authorization-implicit-consent` — auto-approves access (no consent screen)
- `invalidation_flow: default-provider-invalidation-flow` — required since Authentik 2026.2; controls session invalidation behavior

Each application references its provider via `!KeyOf`. All applications use `policy_engine_mode: any` — a user needs to match **any one** bound group policy to gain access.

### Session Duration (how often you re-login)

The SSO session length is set declaratively on the `default-authentication-login` user-login stage in `configmap-blueprints.yaml`:

- `session_duration: "days=30"` — overrides Authentik's shipped default of `seconds=0` (a browser-session cookie with a short server-side lifetime). A persistent 30-day session survives browser restarts, so app re-authentication stays transparent (no password prompt) for 30 days. This applies to **all** Authentik-protected apps.
- `remember_me_offset: "days=60"` — extends the session further when a user ticks "stay signed in" at login.

The Claws OIDC provider (`claws-oidc`) additionally pins longer token lifetimes so it bounces back to Authentik less often: `access_token_validity: "hours=24"` (was the 1-hour default) and `refresh_token_validity: "days=90"`. These are the levers to adjust if login frequency needs tuning.

### Groups and Access Control

Four groups provide role-based access control. Most applications are bound to a specific category group (order 0) plus the `all-apps` fallback group (order 1) — matching either grants access under `policy_engine_mode: any`. **Open WebUI is the one exception**: it has only a single `all-apps` binding (order 0) and no category-specific group, so any `all-apps` member can reach it regardless of `media`/`home`/`infra` membership.

| Group | Purpose | Applications |
|-------|---------|-------------|
| `all-apps` | Full access to all protected services | Bound to every ForwardAuth/OIDC application (fallback for most, sole binding for Open WebUI) |
| `media` | Media automation services | Sonarr, Radarr, Prowlarr, Bazarr, Transmission, Jellyfin (OIDC), Jellyseerr (OIDC), Seerr (OIDC) |
| `home` | Home/lifestyle services | Mealie (OIDC), Bin Scraper (OIDC) |
| `infra` | Infrastructure admin tools | Grafana, Prometheus, Datasette, Headlamp (OIDC), Proxmox (OIDC), Claws (OIDC), Forgejo (OIDC) |

**Users** (declared in blueprint, group memberships are fully declarative):

| User | Groups | Notes |
|------|--------|-------|
| `brendan` | `all-apps`, `infra`, `authentik Admins` | Admin user; `all-apps` + `infra` are redundant while in Admins (superusers bypass policy checks) but kept as defense-in-depth |
| `eileen` | `media`, `home` | Restricted to media and home services only |

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

Three Traefik `Middleware` CRDs work together as a chain:

1. **`authentik-strip-headers`** — Removes all `X-authentik-*` headers and `Authorization` from incoming requests before ForwardAuth processes them. Defense-in-depth against header forgery.

2. **`authentik-forwardauth`** — Sends a subrequest to Authentik at `http://authentik-server.default.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik`. On success, forwards `X-authentik-username`, `X-authentik-groups`, `X-authentik-email`, `X-authentik-name`, and `X-authentik-uid` headers to the backend.

   `trustForwardHeader` is deliberately `false`. Authentik's outpost selects which proxy application to evaluate from `X-Forwarded-Host`; with the flag on, Traefik would copy the client's value into the auth subrequest while still routing the real request by the `Host` header, letting a client pick a different application's policy bindings than the backend it reaches. With it off, Traefik derives `X-Forwarded-Host` from `req.Host` and `X-Forwarded-Uri` from the real request URI, which is exactly what the outpost needs. This is belt-and-braces: the `websecure` entrypoint (`forwardedHeaders.insecure: false`, no `trustedIPs` — pinned explicitly in `clusters/my-cluster/infrastructure/traefik/release.yaml`) already deletes all client-supplied `X-Forwarded-*` headers before routing.

3. **`authentik-auth`** — Chain middleware combining strip → forwardauth. This is what services reference.

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
| Datasette | ForwardAuth gates access |

### Native OIDC Integration

| Service | SSO Behavior |
|---------|-------------|
| Mealie | OIDC via Authentik; `OIDC_AUTH_ENABLED=true`, `OIDC_AUTO_REDIRECT=false`. No ingress annotation needed. |
| Open WebUI | OIDC via Authentik; OAuth2 callback at `/oauth/oidc/callback`. No ingress annotation needed. |
| Jellyfin | OIDC via `jellyfin-plugin-sso` 3.5.2.4 (plugin binary is a manual install; its OID config, `SchemeOverride`, the login-page button and the plugin repository are reconciled by the `config-reconciler` sidecar in `apps/jellyfin/deployment.yaml`, see #817); callback at `/sso/OID/redirect/authentik`. No ingress annotation needed. |
| Jellyseerr | OIDC via Authentik (configured via Jellyseerr Settings → Users); callback at `/api/v1/auth/oidc-callback`. No ingress annotation needed. |
| Seerr | OIDC via Authentik, provider `seerr-oidc`; preview image `ghcr.io/seerr-team/seerr:preview-new-oidc` (upstream PR #2715, unreleased) has no UI for OIDC, so the provider is written into `settings.json` by the `oidc-init` initContainer in `apps/seerr/deployment.yaml`. No ingress annotation needed. |
| Headlamp | OIDC via Authentik; callback at `/oidc-callback`. Access restricted to `infra` group. |
| Proxmox | OIDC via Authentik realm `authentik`; callback at `/`. Realm configured manually on Proxmox host (not GitOps). Access restricted to `infra` group. |
| Bin Scraper | OIDC via Authentik; callback at `/auth/callback`. Access restricted to `home` group. Client env (`OIDC_ISSUER`/`OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET`/`OIDC_REDIRECT_URI`) lives in `apps/bin-scraper/deployment.yaml`; issuer URL requires its trailing slash. |
| Claws | OIDC via Authentik; callback at `/auth/callback`. Bearer-token API access (webhooks) still works in OIDC mode. Access restricted to `infra` group. Staging deployment in-repo; external `claws.home.bstjohn.net` host configured out-of-band. |
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
| Homepage | Public dashboard, no sensitive data |
| Immich | Has its own auth; mobile apps need direct API access |
| Home Assistant | No ForwardAuth — IoT integrations and the Companion app need direct API access. Native OIDC SSO is available via the vendored `auth_oidc` component; HA's own login form stays enabled. Mobile sign-in uses a device code, not an in-app redirect. |
| Overseerr | Uses Plex auth natively; ForwardAuth would create a double-login |
| Plex | Has its own auth; streaming apps need direct access |
| NAS, UniFi | Have their own auth; infrastructure admin interfaces |
| Awtrix | IoT device, LAN-only |

## Grafana Integration

Grafana uses `auth.proxy` for deeper SSO integration beyond ForwardAuth:

```yaml
auth.proxy:
  enabled: true
  header_name: X-authentik-username
  header_property: username
  auto_sign_up: false
  headers: "Name:X-authentik-name Email:X-authentik-email"
  # Pod-network whitelist is gated by NetworkPolicy (grafana-networkpolicy.yaml) — only Traefik pods can reach :3000.
  whitelist: "10.42.0.0/16"
```

Grafana automatically maps incoming `X-authentik-username` headers to existing user accounts. `auto_sign_up: false` means only users that already exist in Grafana can log in via proxy auth — new accounts must be created by an admin first. The local admin login form remains enabled as a fallback.

**Defense-in-depth for header spoofing**: A NetworkPolicy (`apps/monitoring/grafana-networkpolicy.yaml`) restricts Grafana's ingress on port 3000 to pods in the `traefik` namespace only — no other in-cluster pod can reach Grafana directly to forge `X-authentik-*` headers. The `whitelist: 10.42.0.0/16` is a secondary safeguard; with the NetworkPolicy enforcing source restriction, it serves as belt-and-suspenders rather than the primary control.

## Security Model

| Attack Vector | Risk | Mitigation |
|---------------|------|------------|
| External (through Traefik) | None — Traefik overwrites headers | Strip-headers middleware (defense-in-depth) |
| Internal (bypasses Traefik) | None — only Traefik pods can reach Grafana port 3000 | NetworkPolicy `grafana-ingress-from-traefik-only`; secondary: `auth.proxy.whitelist: 10.42.0.0/16` |
| Forged `X-Forwarded-Host` (application confusion) | None — entrypoint deletes client `X-Forwarded-*`; ForwardAuth re-derives from `req.Host` | `forwardedHeaders.insecure: false` + no `trustedIPs` on the `web`/`websecure` entrypoints; `trustForwardHeader: false` on `authentik-forwardauth` |

The header-stripping middleware is defense-in-depth: even if Traefik had a bug or partial auth-service failure, client-supplied `X-authentik-*` and `Authorization` headers are cleared before ForwardAuth runs.

## Secrets

All secrets live in the `authentik-secrets` Secret in the `default` namespace.

| Key | Used By | Source |
|-----|---------|--------|
| `AUTHENTIK_SECRET_KEY` | server, worker | Auto-generated by migration job 0001 |
| `AUTHENTIK_BOOTSTRAP_TOKEN` | server | Auto-generated by migration job 0002 |
| `PG_PASS` | server, worker, postgresql | Auto-generated by migration job 0003 |
| `MEALIE_OIDC_CLIENT_SECRET` | mealie | Auto-generated by migration job 0004 |
| `OPEN_WEBUI_OIDC_CLIENT_SECRET` | open-webui | Auto-generated by migration job 0004 |
| `JELLYFIN_OIDC_CLIENT_SECRET` | authentik-worker (blueprint) + jellyfin `config-reconciler` sidecar | Auto-generated by migration job 0004 |
| `JELLYSEERR_OIDC_CLIENT_SECRET` | authentik-worker (injected into blueprint) | Auto-generated by migration job 0004 |
| `SEERR_OIDC_CLIENT_SECRET` | authentik-worker (blueprint) + seerr `oidc-init` initContainer | Auto-generated by migration job 0004 |
| `HEADLAMP_OIDC_CLIENT_SECRET` | authentik-worker (injected into blueprint), headlamp-oidc secret | Auto-generated by migration job 0004 |
| `PROXMOX_OIDC_CLIENT_SECRET` | authentik-worker (injected into blueprint) | Auto-generated by migration job 0004 |
| `BIN_SCRAPER_OIDC_CLIENT_SECRET` | authentik-worker (blueprint) + bin-scraper Deployment (`OIDC_CLIENT_SECRET`) | Auto-generated by migration job 0004 |
| `CLAWS_OIDC_CLIENT_SECRET` | authentik-worker (injected into blueprint) + claws-staging | Auto-generated by migration job 0004 |
| `FORGEJO_OIDC_CLIENT_SECRET` | authentik-worker (injected into blueprint) | Auto-generated by migration job 0004 |
| `HOME_ASSISTANT_OIDC_CLIENT_SECRET` | authentik-worker (blueprint) | Auto-generated by migration job 0004 |
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
- Authenticated users get zero Proxmox privileges until an operator grants them: `pveum aclmod / -user <username>@authentik -role PVEAdmin` (or a less-privileged role).
- Users sign in by selecting realm `authentik` on the Proxmox login screen.
