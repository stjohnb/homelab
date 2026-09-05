# Applications Overview

**Reference.** Read this when adding a new service to `apps/`, or need the full list/shape of existing services, service types, or Headlamp/migrations conventions. For cluster-layer infrastructure (Traefik, cert-manager, CI), see [infrastructure-overview.md](infrastructure-overview.md).

Application manifests for a single-node k3s homelab cluster, living in the `apps/` directory of the fleet-infra monorepo. Deployed via Flux CD GitOps to the `default` namespace. For the main entry point, see [OVERVIEW.md](OVERVIEW.md).

The cluster runs 30+ services across media automation, home automation, monitoring, networking, and productivity.

## Architecture

### GitOps Flow

```
Feature Branch → Pull Request → CI Validation → Merge → Flux Reconciliation → Cluster
```

- **CI checks** (all blocking): YAML lint, kustomize build, kubeconform validation, kubesec security scan, Trivy image vulnerability scan (CRITICAL CVEs only, changed images), secret detection, kustomization completeness (verifies all service directories are listed in parent kustomization.yaml), Renovate config validation
- **Kustomize diff comment**: CI posts a PR comment with a unified diff of rendered manifests (base vs PR branch), auto-updated on each push. Non-blocking (`continue-on-error`).
- **Flux health checks**: After applying manifests, Flux verifies critical resources reach Ready status within 5 minutes. Failures trigger Slack notifications. Configured via `spec.healthChecks` on the `apps` Kustomization in `clusters/my-cluster/apps-kustomization.yaml`. Monitored: Deployments (`gatus`, `homepage`, `homepage-limited`, `homepage-router`). The `kube-prometheus-stack` HelmRelease is intentionally excluded — its reconciliation on a single-node cluster routinely exceeds the 5-minute timeout while in 'InProgress' state, producing noisy false-positive Slack alerts. Actual HelmRelease failures are still reported via the `slack-errors` alert, which watches it directly. Intentionally excluded: Immich (depends on NFS from the NAS, which is not always on — would produce false-positive alerts every minute), the standalone `pve-exporter` (a peripheral metric collector with external dependencies).
- **Branch protection**: Direct pushes to `main` are blocked; all changes require PRs
- **No `kubectl apply`**: Flux owns the cluster state (exception: secrets and emergency debugging)

### Repository Layout

```
apps/                            # Within fleet-infra monorepo
├── kustomization.yaml          # Root: lists all service directories as resources
├── priority-classes.yaml       # PriorityClass definitions
├── wildcard-home-cert.yaml     # Shared TLS certificate (*.home.bstjohn.net)
│
├── homepage/                   # Dashboard (entry point for users)
├── gatus/                      # Uptime monitoring + Slack alerts
├── monitoring/                 # Prometheus + Grafana stack (see docs/monitoring.md)
│
├── servarr/                    # Media automation stack (see docs/servarr.md)
│   ├── transmission/           #   Torrent client (WireGuard VPN sidecar)
│   ├── sonarr/                 #   TV show automation
│   ├── radarr/                 #   Movie automation
│   ├── prowlarr/               #   Indexer management
│   ├── bazarr/                 #   Subtitle management
│   └── overseerr/              #   Media request UI
│
├── immich/                     # Photo management (multi-container: server, ML, DB, cache)
├── jellyfin/                   # Media server (jellyfin.home.bstjohn.net)
├── navidrome/                  # Music streaming, Subsonic API (music.home.bstjohn.net)
├── jellyseerr/                 # Media request UI for Jellyfin (jellyseerr.home.bstjohn.net)
├── seerr/                      # Seerr preview with native Authentik OIDC, beside jellyseerr (seerr.home.bstjohn.net)
├── truenas-gate/               # Nginx proxy for NAS-dependent services (see docs/truenas-gate.md)
│
├── arpwatch/                   # ARP monitoring with Slack alerts (hostNetwork)
├── mealie/                     # Recipe manager
├── bin-scraper/                # Council bin collection scraper → MQTT → HA
│
├── authentik/                  # SSO provider (ForwardAuth middleware)
├── headlamp/                   # Kubernetes web UI dashboard (Helm)
│
├── forgejo/                    # Git forge (git.home.bstjohn.net) + 2 backup CronJobs — see docs/forgejo.md, docs/forgejo-mirroring.md
├── forgejo-runner/             # Forgejo Actions runner (dind)
│
├── home-assistant/             # External service proxy (192.168.0.89)
├── music-assistant/            # External service proxy (192.168.0.89:8095, HAOS add-on — Cast bridge for Navidrome)
├── claws/                      # External proxy (192.168.0.73:3000) + containerized staging StatefulSet
├── containerd-gc/              # CronJobs: daily image GC (main 04:00 300s limit; k3s-nas 04:30 1800s limit)
├── admission-error-reaper/  # CronJob: deletes UnexpectedAdmissionError pod tombstones (every 5 min, k3s)
├── config-backup/              # CronJobs: nightly SQLite-consistent backup of the servarr (k3s-nas) and Plex/Jellyfin (k3s) config PVCs (see docs/config-backups.md)
├── ollama/                     # Deployed (GPU node, see docs/gpu-k3s.md) — in-cluster only (no ingress, consumed by API clients via Service DNS)
├── whisper/                    # Deployed (GPU node, audio transcription API, port 9000) — in-cluster only (no ingress)
├── nvidia-device-plugin/       # HelmRelease (GPU node device plugin) + RuntimeClass (see docs/gpu-k3s.md)
├── plex/                       # Deployed (k3s since #800, soft NFS media mount) — ingress still routes via truenas-gate
├── awtrix/                     # External service proxies: kitchen (192.168.0.30:80) + office (192.168.0.160:80), ForwardAuth + injected device Basic auth
├── proxmox/                    # External service proxy (192.168.0.200:8006, IngressRoute)
├── unifi/                      # External service proxy (192.168.0.1:443, IngressRoute)
└── tailnet-dns/                # In-cluster CoreDNS resolver for home.bstjohn.net over the tailnet (#1131)
```

### Service Types

Services fall into three categories:

| Type | Pattern | Examples |
|------|---------|----------|
| **Deployed** | Full Deployment + Service + Ingress + PVC | immich, mealie, homepage, gatus, servarr/*, plex |
| **External proxy** | Endpoints + Service + Ingress (no pods) | home-assistant, music-assistant, awtrix, claws |
| **Helm release** | HelmRelease + HelmRepository CRDs | monitoring/kube-prometheus-stack, headlamp |
| **Multi-deployment** | Multiple Deployments + Services + Middleware | authentik (server, worker, postgresql) |
| **CronJob** | CronJob (no ingress; usually privileged) | containerd-gc, containerd-gc-storage, config-backup, admission-error-reaper |
| **StatefulSet** | StatefulSet + volumeClaimTemplate + Service + Ingress | claws-staging (the repo's only StatefulSet) |

**External proxies** expose devices/VMs on the LAN through the cluster's ingress and TLS, using manually defined Endpoints pointing to static IPs.

**Proxmox and UniFi** use Traefik `IngressRoute` + `ServersTransport` (with `insecureSkipVerify`) instead of standard Ingress, because their backends serve self-signed HTTPS.

### Adding a Service to Kustomize

Every service directory must be listed in `apps/kustomization.yaml` under `resources:`. Each service directory has its own `kustomization.yaml` listing its manifests.

### Decommissioning a Service

Used twice now (Datasette #911/#912, Vaultwarden + Open WebUI #916/#922) — same shape both times:

- **Delete** the Deployment, Service, and Ingress manifests, plus the Gatus check and Homepage tile.
- **Retain** the PVC (rewrite it to only `metadata` + `spec`, no owning Deployment) with `kustomize.toolkit.fluxcd.io/prune: disabled` and a comment explaining why — this makes merging the removal PR unable to destroy data. The operator extracts/verifies anything needed from the volume, then deletes the PVC by hand; that step is explicitly out of scope for the PR.
- **Tombstone**, don't delete, any Authentik blueprint entries (`authentik_providers_proxy.proxyprovider` / `authentik_core.application` / policy bindings) by setting `state: absent` instead of removing them from `configmap-blueprints.yaml`. Blueprints are apply-only and never prune — deleting the YAML block entirely would leave the object live in Authentik's DB forever with no way to remove it via GitOps.
- Update docs (this file, `OVERVIEW.md`, `authentik.md`) in the same PR — don't leave stale references pointing at a service that's gone.

## Key Patterns

### TLS: Shared Wildcard Certificate

A single `Certificate` resource (`wildcard-home-cert.yaml`) covers `*.home.bstjohn.net` and `home.bstjohn.net`. All ingresses reference `secretName: wildcard-home-tls`.

**Never** add `cert-manager.io/cluster-issuer` annotations to ingresses or create per-service Certificate resources — this creates DNS pollution that breaks wildcard resolution (see [../AGENTS.md](../AGENTS.md) for the repo rule and [OVERVIEW.md](OVERVIEW.md#tls-shared-wildcard-certificate) for the explanation).

### Ingress Convention

```yaml
spec:
  ingressClassName: traefik-traefik    # NOT "traefik"
  tls:
    - hosts: [service.home.bstjohn.net]
      secretName: wildcard-home-tls    # Shared cert, never per-service
```

### Storage Strategy

| Class | When to use | Survives NAS offline | Examples |
|-------|-------------|--------------------------|----------|
| `local-path` | Infrastructure, config, databases | Yes | gatus, immich DB, monitoring |
| NFS (`192.168.0.128`) | Large media/data | No (pod waits) | transmission downloads, sonarr/radarr media, immich photos |

NFS PersistentVolumes are defined with static `nfs.server` and `nfs.path` fields (NFSv3). Pods gracefully wait and resume when the NAS comes back online.

### Database Backups

The Immich PostgreSQL database is backed up via a CronJob (`immich-db-backup`) that runs `pg_dump --format=custom` every 6 hours (`0 */6 * * *`, Europe/London). Backups are written to `/mnt/SSD-POOL/media/backups/immich/` on the NFS media share, with a grandfather-father-son retention (last 2 days, then daily/weekly/monthly buckets — shared script documented in [docs/postgres.md](postgres.md#backups)). Since the NAS is not always on, deadline-killed runs during a NAS outage (pod stays Pending, killed after 30 min by `activeDeadlineSeconds`) remain expected and are filtered from alerting — `failedJobsHistoryLimit: 1` keeps the job list clean. Any other non-zero exit is a real failure and pages, because the job verifies dump contents (row counts, TOC, size floor) rather than trusting `pg_dump`'s exit status alone. See [docs/immich.md](immich.md) for backup verification and restore procedures.

### TrueNAS Gate

Services whose ingresses route through `truenas-gate` — an nginx reverse proxy that shows a "wake the NAS" page when backends are unavailable instead of a raw error. Currently gated: Immich, Plex, Transmission. Plex's ingress still targets `truenas-gate` (not the `plex` Service directly) even though Plex now runs on the always-on node — that indirection is deliberate, not legacy cruft: it covers the window where a Plex pod is *restarted* while the NAS is asleep and gets stuck in `ContainerCreating` (a soft mount rescues a running pod, not a starting one). The gate also serves the wake page unconditionally at `wake.home.bstjohn.net`, since Plex and Jellyfin no longer fall through to it while the NAS sleeps. See [docs/truenas-gate.md](truenas-gate.md).

### Gatus Alerting for NFS-Dependent Services

Sonarr, Radarr, Bazarr, Immich, and Transmission are placed in a `media-services` group in `apps/gatus/config.yaml` with **no per-service Slack alerts** — this is deliberate, not an oversight (#93). A dedicated `NAS` endpoint carries the alert instead ("NAS is down — Sonarr, Radarr, Bazarr, Immich, and Transmission will also be unavailable") and acts as the sole canary for the group. The original ask was for Gatus to alert on these services during normal operation but suppress the alert specifically when the NAS is down (so an app-level crash — a bad Sonarr config, Immich's ML container OOMing — would still page while the NAS is up); Gatus has no built-in way to make one endpoint's alert conditional on another's status, so the group was left alert-free and NAS-down is treated as the explanation for the whole group being unreachable. Net effect: an app-level failure in one of these services while the NAS is healthy currently produces no Slack notification — known and accepted, not a target for automatic fixing without new Gatus capability. Jellyfin and Plex left this group in #800: they run on the always-on node behind a soft NFS mount, so a failure is real rather than expected NAS downtime, and both now alert to Slack ungrouped. Navidrome (#959) joined them directly — as a read-only NFS consumer it went straight into the always-on group rather than through a migration, and likewise alerts ungrouped. The `NAS` check itself is a TCP probe against `192.168.0.128:2049` (NFS) — it proves the NFS listener is up, not that the ZFS pool imported successfully.

### External Service Proxy Pattern

To expose a LAN device through the cluster ingress:

```yaml
# endpoints.yaml — static IP of the device
apiVersion: v1
kind: Endpoints
metadata:
  name: my-device
subsets:
  - addresses: [{ip: "192.168.0.X"}]
    ports: [{port: YYYY, protocol: TCP}]

# service.yaml — headless service matching the endpoints
# ingress.yaml — standard ingress with wildcard-home-tls
```

### SSO: Authentik ForwardAuth

Authentik provides centralized SSO using two mechanisms:

1. **ForwardAuth (12 services)** — Traefik intercepts requests and validates sessions with Authentik's embedded outpost. Protected ingresses add `traefik.ingress.kubernetes.io/router.middlewares: default-authentik-auth@kubernetescrd`. Services: Sonarr, Radarr, Prowlarr, Bazarr, Transmission, Grafana, Prometheus, Awtrix Kitchen, Awtrix Office, Homepage, Navidrome, Music Assistant.

2. **Native OIDC (12 services)** — Services handle authentication natively and redirect to Authentik's login flow. No ingress annotation needed. Services: Mealie (`OIDC_AUTH_ENABLED=true`), Jellyfin (via `jellyfin-plugin-sso`), Jellyseerr (configured in web UI), Headlamp, Proxmox, Bin Scraper, Claws, Forgejo, Seerr (`settings.json` written by the `oidc-init` initContainer), Home Assistant (provider wired but not yet consumed HA-side — pending vendoring of `auth_oidc` in `home-assistant-config`), Container Registry, Garden.

The ForwardAuth address uses FQDN `authentik-server.default.svc.cluster.local` because Traefik runs in its own namespace. Two outposts are declaratively configured in the blueprint — the embedded outpost carries the 12 `.home.` providers and the standalone `ext-proxy-outpost` (`apps/authentik/deployment-proxy-ext.yaml`) the 12 `.ext.` ones, so ext logins redirect to `auth.ext.bstjohn.net` (#1111); each `authentik_outposts.outpost` entry lists its providers by `!KeyOf` reference, ensuring provider-to-outpost attachment is version-controlled. Proxy providers, applications, users, groups, and per-app policy bindings are all configured declaratively via Authentik blueprints (`configmap-blueprints.yaml`), which define 24 ForwardAuth proxy providers (one home and one ext per service), 24 proxy applications, 12 OIDC providers (+12 provider-less ext bookmarks), 4 groups (`all-apps`, `media`, `home`, `infra`), 2 users, and 72 policy bindings. Each application is bound to a category-specific group plus the `all-apps` fallback group using `policy_engine_mode: any`. Group memberships are fully declarative — manual changes in the Authentik UI are reverted on reconciliation. Gatus is intentionally excluded from ForwardAuth so that monitoring remains accessible during an Authentik outage. Grafana additionally uses `auth.proxy` for automatic user creation from Authentik sessions. See [docs/authentik.md](authentik.md) for the full architecture, blueprint configuration, access control model, protected service list, and security model.

### Ingress (Home and Ext Domains)

All services use `*.home.bstjohn.net` (LAN, 192.168.0.251) ingresses, and each one carries a sibling `*.ext.bstjohn.net` host on the same resource — ForwardAuth services are the exception: their ext host lives in a sibling `<svc>-ext` Ingress because it needs the other middleware chain (#1111). Every other service carries both hosts on one resource. Tailscale split DNS sends `home.bstjohn.net` to the in-cluster `tailnet-dns` resolver at `100.78.7.18` (`apps/tailnet-dns/`), which answers `100.78.7.18` for the apex and every subdomain, so `.home` reaches Traefik with no subnet router; the openclaw subnet router remains the fallback for encrypted-DNS clients. `*.ext` resolves to the `k3s` node's tailnet address (100.78.7.18) and reaches Traefik with no subnet router involved either. See [Remote access over Tailscale](infrastructure-overview.md#remote-access-over-tailscale).

### Health Probes

All deployed services have liveness, readiness, and (where needed) startup probes. Typical patterns:

- **HTTP services**: `httpGet` on a health/ping endpoint (e.g., `/ping`, `/health`, `/api/server/ping`)
- **Database services**: `exec` commands (e.g., `pg_isready -U immich`, `valkey-cli ping`)
- **TCP services**: `tcpSocket` check on the main port (e.g., PostgreSQL 5432, Valkey 6379)
- **Slow-starting services**: `startupProbe` with generous failure thresholds (e.g., Immich ML allows ~5 min for model loading). Liveness and readiness probes only activate after the startup probe succeeds.
- **Readiness probes**: Control traffic routing — failures remove the pod from Service endpoints without triggering restarts. All Immich containers have readiness probes to ensure the pod is only marked Ready when all four containers (server, ML, postgres, valkey) are functional.

External proxy services (home-assistant, awtrix, etc.) do not have probes since they have no pods in the cluster. Plex, despite still being routed through `truenas-gate`, runs a real in-cluster pod on `k3s` and has startup/liveness/readiness probes against `/identity` (unauthenticated) — the startup probe allows up to 15 minutes because the first start after a database restore/upgrade must not be interrupted.

### Headlamp (Helm chart `0.40.x`)

Lightweight Kubernetes web UI (CNCF sandbox project) providing read-only cluster visibility. Deployed as a HelmRelease in the `default` namespace.

- **Source files**: `apps/headlamp/release.yaml`, `apps/headlamp/rbac.yaml` (HelmRelease + RBAC); HelmRepository source is in `clusters/my-cluster/infrastructure/headlamp/source.yaml` (flux-system namespace — see [infrastructure-overview.md](infrastructure-overview.md#helmrepository-namespace-requirement))
- **Helm repo**: `https://kubernetes-sigs.github.io/headlamp/`
- **URL**: `https://dashboard.home.bstjohn.net`
- **TLS**: Uses shared `wildcard-home-tls` certificate
- **Auth model**: Users log in via Authentik SSO (OIDC), gated by membership in the Authentik `infra` group. Headlamp's backend proxies the user's Authentik **ID token** to the Kubernetes API server — it does *not* substitute its own ServiceAccount — so the kube-apiserver must be configured with `oidc-issuer-url` / `oidc-client-id` / `oidc-username-claim` / `oidc-groups-claim` on the `k3s` node (`/etc/rancher/k3s/config.yaml`, see [infrastructure-overview.md](infrastructure-overview.md)). Without those flags every request 401s and Headlamp falls back to its paste-a-token screen — the #1024 symptom. Authorization is the `authentik-infra-readonly-binding` ClusterRoleBinding mapping group `oidc:infra` to `read-only-cluster-viewer`; API discovery and `selfsubjectrulesreviews` come free from k3s's default `system:discovery` / `system:basic-user` bindings on `system:authenticated`. The `headlamp` ServiceAccount and its `headlamp-readonly-binding` remain for the break-glass token path.
- **OIDC secret**: `headlamp-oidc` Secret in `default` (keys: `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `OIDC_ISSUER_URL`, `OIDC_SCOPES`). Populated by `migrations/0011-headlamp-oidc-secret.sh`; the live cluster was rekeyed from the original lowercase camelCase names by `migrations/0012-headlamp-oidc-rekey.sh`. The Helm chart mounts this Secret via `envFrom: secretRef` and the container args reference the keys as `$(OIDC_CLIENT_ID)` etc. — uppercase names are required. Client secret also lives in `authentik-secrets.HEADLAMP_OIDC_CLIENT_SECRET` for the Authentik blueprint to reference via `!Env`.
- **Legacy fallback**: `migrations/0007-headlamp-token.sh` / `headlamp-token` secret remain in place. They are unused by the normal OIDC flow but preserved so users can still paste a token via the login screen if Authentik is down.
- **Session TTL workaround**: `config.sessionTTL: null` overrides the chart's default value that generates a `-session-ttl` flag the binary doesn't recognize (chart bug).
- **Key values**: `clusterRoleBinding.create: false` (prevents the chart's default cluster-admin binding)
- **Install/upgrade timeouts**: `install.timeout: 10m` and `upgrade.timeout: 10m` — explicitly set (vs the Flux default 5m) as defence-in-depth against slow secret provisioning or image-pull races during upgrades. Note: a `Stalled` (`RetriesExceeded`) HelmRelease does not self-recover — bumping the spec generation (e.g., by changing these values) causes helm-controller to reset the failure counter and retry.
- **Why apps layer, not infrastructure**: Headlamp was originally in `infrastructure/` but was moved to `apps/` because infrastructure uses `wait: true` — a Headlamp failure cascaded via the `dependsOn` chain and blocked all cluster reconciliation. Only foundational components (cert-manager, traefik) should be in the infrastructure layer.

### Arpwatch Notifications

Arpwatch monitors ARP traffic on the host network to detect new devices and address changes. It uses a dedicated container image (`registry.home.bstjohn.net/st-john-software/arpwatch`) built by `.github/workflows/build-arpwatch.yml` with calver tags (`vYYYY-MM-DD.N`). The image bundles arpwatch, jq, curl, and the full IEEE OUI vendor database (`ethercodes.dat`, downloaded from `standards-oui.ieee.org` at build time via awk) — this ensures vendor lookups work correctly without relying on Alpine's bundled stub. It runs with `-F` (foreground) mode which keeps the process as PID 1 while still invoking sendmail for alerts. The sendmail binary is replaced by a symlinked shell script (`notify-slack.sh` from a ConfigMap) that formats alerts as Slack messages using `jq` for JSON construction. The Slack webhook URL comes from the shared `gatus-secrets` secret. Requires `NET_RAW` capability for ARP monitoring (not fully privileged). The script silently drops alerts where the source IP is `0.0.0.0` — these are normal ARP probes (RFC 5227) and DHCP discovery packets that generate harmless "flip flop" noise when multiple devices probe the network.

### Tailnet DNS

`apps/tailnet-dns/` runs CoreDNS `1.14.7`, authoritative for `home.bstjohn.net` on the tailnet, so off-LAN Tailscale devices reach `.home` services without the openclaw subnet router (#1131). Pinned to the `k3s` node via `nodeSelector: kubernetes.io/hostname: k3s` and bound only to its tailnet address: `hostPort: 53` UDP+TCP with `hostIP: 100.78.7.18`, while the container itself listens on unprivileged `5353`. The container keeps `capabilities: drop: [ALL]` but must re-add `NET_BIND_SERVICE`: the upstream image's `/coredns` binary is built with `setcap cap_net_bind_service=+ep`, and under `allowPrivilegeEscalation: false` the kernel refuses to exec it with an empty permitted set — `exec /coredns: operation not permitted` at startup (#1138). Uses `strategy: Recreate` because two pods cannot hold the same hostPort. No Service and no Ingress — nothing routes to it in-cluster. Monitored by the `Tailnet DNS` Gatus check (`apps/gatus/config.yaml`). The Tailscale split-DNS nameserver pointing at `100.78.7.18` is a manual admin-console setting, not tracked in Git — see [infrastructure-overview.md](infrastructure-overview.md#remote-access-over-tailscale).

### Garden

Garden (`St-John-Software/Garden`) is a Next.js + Prisma app for garden planning, image `registry.home.bstjohn.net/st-john-software/garden`, private and pulled with `imagePullSecrets: [registry-pull]`. Its database lives in the shared PostgreSQL instance — see [postgres.md](postgres.md) — with schema owned entirely by Prisma migrations, applied by an `initContainer` running `npx prisma migrate deploy` from the same image on every rollout, so there is never a manual migration step. There is no S3-compatible object store in this cluster, so photo uploads use `PHOTO_STORAGE_DRIVER=local` with bytes written to a `local-path` PVC mounted at `PHOTO_LOCAL_ROOT=/var/photos`; only the storage key is persisted in Postgres, so a later move to an `s3` driver needs a file copy, not a data migration. `.github/workflows/update-garden.yml` mirrors `update-bin-scraper.yml` for the image-bump CD handshake. Authentication is native OIDC inside the app (client `garden`, issuer `https://auth.home.bstjohn.net/application/o/garden/`, redirect `https://garden.home.bstjohn.net/auth/callback`), bound to the `home` and `all-apps` Authentik groups; the client secret is `authentik-secrets`/`GARDEN_OIDC_CLIENT_SECRET` and the session HMAC key is `garden-session`/`session-secret` (#1037). The Ingress carries no ForwardAuth middleware by design — that would break the bearer-token path and put a redirect in front of `/api/health`, which stays open for the kubelet and Gatus probes. Garden's `/seeds/import` seed-packet OCR calls the in-cluster Ollama at `SEED_OCR_URL=http://ollama:11434` with `SEED_OCR_MODEL=minicpm-v` and `SEED_OCR_TIMEOUT_MS=180000`; the model is preloaded declaratively by the `model-preload` container in `apps/ollama/deployment.yaml` (see `docs/gpu-k3s.md`).

### Secret Migration Jobs

`migrations/` (at the repository root, deployed via a dedicated Flux Kustomization) contains a single idempotent Job that auto-generates secret values and writes them into the `authentik-secrets` Secret. This avoids hardcoding generated secrets in Git while keeping them reproducible across fresh cluster installs.

**Provisioning split:** credentials for accounts shared *between fleet-managed services* (e.g. the registry's `ci`/`puller` identities, see [docs/registry.md](registry.md)) are minted here, by a migration script — never hand-created with `kubectl create secret` — so they stay reproducible on a fresh cluster and out of Git. Credentials for actual people are never provisioned this way: real users authenticate through Authentik SSO instead of a locally managed password.

**Migrations are fully automatic — never a manual action.** Flux reconciles `./migrations` every minute, `job.yaml` carries `kustomize.toolkit.fluxcd.io/force: enabled`, and the scripts are mounted from a hash-suffixed ConfigMap, so a merged PR that adds or edits a script re-runs the Job within ~1 minute with no human step. PR descriptions and plans must not list "run migration NNNN" as a manual action before or after merge (#979).

The `migrations` Kustomization depends on `infrastructure` (not `config`) and runs in parallel with the `config` layer. The `apps` Kustomization depends on both `config` and `migrations`, so application pods only start after secrets are ready. See [infrastructure-overview.md](infrastructure-overview.md#reconciliation-layers) for the full dependency chain.

**Migration scripts** (each targets a distinct key in `authentik-secrets`):

| Script | Key populated |
|--------|--------------|
| `0001-authentik-secret-key.sh` | `AUTHENTIK_SECRET_KEY` |
| `0002-authentik-bootstrap-token.sh` | `AUTHENTIK_BOOTSTRAP_TOKEN` |
| `0003-pg-pass.sh` | `PG_PASS` |
| `0004-oidc-client-secrets.sh` | All OIDC client secrets in `authentik-secrets`: `MEALIE_`, `JELLYFIN_`, `JELLYSEERR_`, `HEADLAMP_`, `PROXMOX_`, `BIN_SCRAPER_`, `CLAWS_`, `FORGEJO_`, `SEERR_`, `HOME_ASSISTANT_`, `REGISTRY_`, `GARDEN_` (each suffixed `_OIDC_CLIENT_SECRET`). Marked `# migration: repeatable` — re-runs every invocation so appended keys reach existing clusters. |
| `0006-fix-transmission-pvc-access-mode.sh` | Migrates Transmission PVC access mode |
| `0007-headlamp-token.sh` | `headlamp-token` (ServiceAccount token) |
| `0011-headlamp-oidc-secret.sh` | `headlamp-oidc` Secret (OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, OIDC_ISSUER_URL, OIDC_SCOPES) |
| `0012-headlamp-oidc-rekey.sh` | Renames `headlamp-oidc` keys from lowercase camelCase to uppercase env-var style; restarts `headlamp` deployment |
| `0017-forgejo-runner-secret.sh` | `forgejo-runner-secret` Secret (keys: `uuid`, `token`) — registers the forgejo-runner via `forgejo-cli` exec, see [docs/forgejo-actions.md](forgejo-actions.md) — secret is generated and consumed inside a single in-pod shell (#902) |
| `0019-forgejo-oidc-auth-source.sh` | Creates the Forgejo `authentik` OAuth2 auth source via `forgejo admin auth add-oauth` exec, then restarts `deployment/forgejo` so the new source is served — see [docs/forgejo.md](forgejo.md#authentik-sso) — client secret is fed over stdin, never as an exec argument (#902) |
| `0020-bin-scraper-session-secret.sh` | `bin-scraper-session` Secret (`session-secret` key) |
| `0021-registry-credentials.sh` | `registry-auth` (htpasswd for `ci`/`puller`, `oidc.json`, plaintext credentials) and `registry-pull` (dockerconfigjson) for zot — see [docs/registry.md](registry.md) |
| `0024-postgres-superuser.sh` | `postgres-superuser` Secret (`POSTGRES_PASSWORD` key) for the shared PostgreSQL instance — 48 alphanumeric chars, deliberately excluding punctuation because later per-app migrations interpolate passwords into SQL string literals, see [docs/postgres.md](postgres.md) |
| `0025-authentik-db.sh` | Creates the `authentik` role and database on the shared PostgreSQL instance and copies the database over from the retired `authentik-postgresql` pod with `pg_dump`/`pg_restore` — the app password is read from `authentik-secrets`/`PG_PASS` and fed to the pod over stdin, never as an exec argument (#902). Asserts `authentik_core_user` is non-empty and drops the half-restored database if not, so a retry starts clean |
| `0026-immich-db.sh` | Same shape as `0025` for the `immich` role and database, dumping from the in-pod `immich-postgres` sidecar. The role is `SUPERUSER` because Immich creates and updates extensions on upgrade; asserts both `asset` and `"user"` are non-empty. Requires the Immich pod to be running, so it retries while the NAS is asleep |
| `0027-immich-drop-pgvecto-rs.sh` | Drops the leftover pgvecto.rs `vectors` extension and schema from the `immich` database once VectorChord has taken over. Gated on `vchord` being installed and deliberately without `CASCADE` — if anything still depends on `vectors` the migration fails and is retried rather than dropping embedding columns |
| `0028-garden-db.sh` | Creates the `garden` role and database on the shared PostgreSQL instance via a `psql` exec — the generated password is fed to the pod over stdin, never as an exec argument (#902) — then writes `garden-db-secret` with `DATABASE_URL`. Unlike `0025`/`0026`, Garden is a brand-new app so there is no prior database to copy from |
| `0029-garden-session-secret.sh` | `garden-session` Secret (`session-secret` key) — HMAC key for Garden's signed session cookie, same shape as `0020` |

**Job design:**
- A single Job (`migration-runner`) runs `run-migrations.sh` which orchestrates numbered scripts in lexicographic order.
- **State tracking**: Execution state is persisted in a ConfigMap (`migration-state`, key per script *filename*, value like `completed:<timestamp>:<rc>`). Completed scripts are never re-run; failed scripts are retried on the next invocation. **State is keyed by filename, not content** — editing a script that is already `completed:` has no effect on an existing cluster. A script that must re-run after being edited (currently only `0004-oidc-client-secrets.sh`, whose `KEYS` array grows as OIDC services are added) declares `# migration: repeatable` on a line of its own within its first 20 lines; `run-migrations.sh` then never skips it. Only mark a script repeatable if it short-circuits on every item it has already completed — one-way migrations such as `0006` (deletes a PVC/PV) and `0012` (rekeys a Secret) must stay one-shot. Ignoring this rule is issue #963: `REGISTRY_OIDC_CLIENT_SECRET` was appended to `0004` on 2026-08-27, never generated, and `0021-registry-credentials.sh` then failed every reconcile for want of it, leaving the `registry` pod stuck in `ContainerCreating` on a missing `registry-auth` Secret.
- Scripts also check if their target key already exists in `authentik-secrets` before generating — defense-in-depth against re-runs.
- Every generator asserts the length of its `tr -dc ... | head -c N || true` output before writing it. The `|| true` suppresses SIGPIPE from `tr`, so it would otherwise also mask a genuinely failed pipeline and write a short or empty value that is never regenerated (each script short-circuits on "already exists"). A failed assertion exits non-zero, is recorded as `failed:` in `migration-state`, and is retried on the next run.
- `kustomize.toolkit.fluxcd.io/force: enabled` — Flux deletes and recreates the Job on every reconcile. Re-runs are safe because of ConfigMap state tracking.
- `ttlSecondsAfterFinished: 600` — completed/failed jobs auto-deleted after 10 minutes.
- `backoffLimit: 0` — no retries; Flux's reconcile loop provides the retry mechanism.
- `activeDeadlineSeconds: 600` — job killed if it runs longer than 10 minutes (bumped from an original 120s to accommodate migration `0006`, which scales down Transmission and waits for PVC/PV deletion).
- **Failure alerting**: the `Migration Runner Job Failed` Grafana rule (`apps/monitoring/kube-prometheus-stack.yaml`, `CronJob Monitoring` group) fires on `kube_job_status_failed` for `migration-runner`, and the `migrations` Kustomization is in the `slack-errors` Flux Alert so build/apply errors on `./migrations` also reach Slack.
- Image: `alpine/k8s:1.33.3` (includes `kubectl`, `base64`, `tr`).

**RBAC:** A dedicated `migration-runner` ServiceAccount with a Role that allows `get`/`patch` on named secrets (`authentik-secrets`, `headlamp-oidc`, etc.) plus `create` on secrets namespace-wide (Kubernetes silently ignores `resourceNames` on `create` verbs). Scripts that use `kubectl apply` to create a secret must have both `get` and `patch` on that secret by name — `kubectl apply` first issues a GET to detect whether to create (404) or patch (200); the GET returns 403 if `get` is missing on that resource name, causing the script to fail under `set -e` before the already-permitted `create` path is reached. Scripts that scale deployments require explicit permission on `deployments/scale` as a separate subresource — a grant on `deployments` alone does not cover it. The `deployments/scale` rule intentionally omits `resourceNames` — k3s does not reliably evaluate `resourceNames` for subresource authorization, so the restriction is silently ignored and causes permission denied errors at runtime. This is a known k3s limitation; the trade-off (SA can scale any deployment in `default`, not just `transmission`) is acceptable for a short-lived migration Job. A separate `ClusterRole`/`ClusterRoleBinding` (`migration-runner-pv`) grants PV-level delete access for the Transmission PVC access mode migration (script `0006`). Script `0017` needs `pods/exec` to run `forgejo-cli` inside the running forgejo pod; like `deployments/scale`, this can't be scoped by `resourceNames` (Deployment pod names change across rollouts), so the SA can exec into any pod in `default` — accepted for the same reason as the scale grant, see the comment in `migrations/rbac.yaml`. It also needs `get` on `pods`: `kubectl exec` issues a GET on the named pod to resolve its default container before opening the exec stream, so `pods/exec` alone fails with `cannot get resource "pods"`. `forgejo` was added to the `deployments` rule's `resourceNames` (alongside `transmission`, `headlamp`) so script `0019` can `kubectl rollout restart deployment/forgejo` after adding the OAuth2 auth source — the running server only registers goth providers at startup, so a restart is required for the new source to take effect.

**Known limitation (issue #719, closed 2026-08-05 as a one-off — the underlying bug was never fixed):** every step in `run-migrations.sh` runs each script to completion with no per-script timeout, so a single hung script can consume the whole `activeDeadlineSeconds: 600` Job deadline with nothing written to `migration-state` and no diagnosis beyond a generic "Pod Failed" alert. `0019-forgejo-oidc-auth-source.sh` is the concrete risk: it resolves a forgejo pod by `status.phase=Running` and then runs two unbounded `kubectl exec` calls against it (every other step in that script is time-bounded, e.g. `kubectl rollout status --timeout=120s`). If Flux applies a `apps/forgejo/deployment.yaml` change in the same reconcile — Forgejo uses `strategy: Recreate`, so there's a window with zero forgejo pods — the exec's target pod can be terminated mid-call and the stream never returns. Separately, `kubectl rollout status` on line matching `deployment/forgejo` issues a collection **LIST** against `deployments`, which RBAC can never authorize via a `resourceNames`-scoped rule (see the RBAC paragraph above) — `migrations/rbac.yaml`'s `deployments` rule only grants `get`/`patch`/`watch` by name, no `list`, so that call fails with a `forbidden` error today; the script logs it but treats the resulting non-zero as “rollout still in progress” rather than failing loudly. A future fix should wrap each migration script in a `timeout` (a value comfortably under `activeDeadlineSeconds`) inside `run-migrations.sh`, and either grant `list` on `deployments` or drop the `rollout status` call from `0019`.

**Critical constraint:** The `authentik-secrets` Secret **must not** be declared as a manifest resource. If Flux SSA-applies an empty Secret definition, it resets the `.data` field on every reconciliation, wiping all populated keys. The secret is created by the migration job itself on first run.

`AUTHENTIK_BOOTSTRAP_PASSWORD` is intentionally excluded from the migration jobs — it must be provided manually at initial setup (see [docs/authentik.md](authentik.md)).

**Adding a new migration:** Add a new script `migrations/NNNN-key-name.sh` and add it to the `configMapGenerator` in `migrations/kustomization.yaml`. The runner picks it up automatically in lexicographic order. **For a new Authentik OIDC client secret, do not add a script** — append the key name to the `KEYS` array in `migrations/0004-oidc-client-secrets.sh`. It is numbered `0004` rather than at the end of the sequence because `0011` and `0019` read keys it generates and the runner executes in lexicographic order. **Never pass secret material as a `kubectl exec` argument** — every argv after `--` becomes a `command=` query parameter on the apiserver request, captured verbatim by Kubernetes audit logging at any level; pipe it over stdin (`printf '%s\n' "$SECRET" | kubectl exec -i ... -- sh -c 'read -r S; ...'`) or generate-and-consume it entirely inside a single in-pod `sh -c` instead (#902). CI's `migration-exec-secrets` job (`scripts/check-migration-exec-secrets.sh`) enforces this — see [Forgejo Actions](forgejo-actions.md#one-time-registration-procedure) for a worked example. **Every Secret a migration reads with `kubectl get secret` must be listed in a `resourceNames` rule with verb `get` in `migrations/rbac.yaml`.** RBAC denial returns Forbidden (non-zero), not NotFound, so a missing grant makes the standard `if kubectl get secret X >/dev/null 2>&1; then … exit 0; fi` idempotency guard permanently report "does not exist" — the script then re-runs `kubectl create secret`, fails `AlreadyExists`, and the Job fails on every 1m reconcile (#923). CI's `migration-secret-rbac` job enforces this. **Do not accompany a new migration with a manual-action note in the PR description** — the runner picks it up on the next reconcile; the only legitimate manual step is supplying an input the script cannot generate itself, such as `AUTHENTIK_BOOTSTRAP_PASSWORD` (#979).

### Claws Staging

`apps/claws/` contains both an external proxy (`claws.home.bstjohn.net` → `192.168.0.73:3000`) and a containerized staging deployment (`claws-staging.home.bstjohn.net`). Both share the same directory.

The staging workload is a StatefulSet (`claws-staging`) with a `volumeClaimTemplate` (50Gi `local-path`, PVC `data-claws-staging-0`), pinned to node `k3s` via `nodeSelector: kubernetes.io/hostname: k3s` — `local-path` volumes are node-local and the other two nodes are powered off most of the day, so a restart always finds its data. The StatefulSet replaced an earlier Deployment on a fixed 1Gi `claws-staging-data` PVC, which could not be grown in place because the `local-path` StorageClass has no `allowVolumeExpansion`; that old claim was carried through the swap with `kustomize.toolkit.fluxcd.io/prune: disabled` so the merge could not delete it, then removed from Git and deleted by hand once the 50Gi volume was verified (#1061). Note that `local-path` enforces no quota, so a runaway `repos/`+`worktrees/` tree on the 50Gi claim could trigger node-wide DiskPressure evictions on the control-plane node.

`terminationGracePeriodSeconds: 420` is 300s scheduler drain + 5s task-cancel + 60s memory flush + headroom — changing claws' `shutdown()` flush cap means changing this number. Resources are `requests: {cpu: 500m, memory: 2Gi}`, `limits: {memory: 6Gi}`, deliberately with no CPU limit: a throttled claude worker process stalls agent runs, so the memory limit is a burst backstop rather than a target.

**Two Secrets, and why.** `claws-config` holds long-lived, rarely rotated static material. As seeded on 2026-09-02 (#1060) it carries 16 keys: `CLAWS_GITHUB_APP_ID`, `CLAWS_GITHUB_APP_PRIVATE_KEY_PATH` (`/etc/claws/github-app/private-key.pem`), `CLAWS_CLAUDE_SETTINGS_JSON`, `CLAWS_SSH_PRIVATE_KEY`, `CLAWS_KUBECONFIG`, `CLAWS_SLACK_WEBHOOK`, `CLAWS_SLACK_PROD_ALERTS_WEBHOOK`, `CLAWS_OPENROUTER_API_KEY`, `OPENAI_API_KEY`, `BRENDAN_SERVER_GMAIL_APP_PASSWORD`, `CLAWS_EMAIL_USER`, `CLAWS_HOME_ASSISTANT_TOKEN`, `CLAWS_HOME_ASSISTANT_BASE_URL`, `CLAWS_AUTH_TOKEN`, `KWYJIBO_AUTOMATION_API_KEY`, `NAMEY_DB_URL`. Deliberately excluded: `CLAWS_OIDC_*`/`CLAWS_ACTIVATION_STATE` (shadowed by the manifest's explicit `env:`, see below), `WHATSAPP_*` (would double-run the openclaw host's WhatsApp session), `CLAWS_STJOHNB_*` (dead env vars, see #1063), and `CLAWS_SLACK_BOT_TOKEN`/`CLAWS_WHISPER_LOCAL_URL` (not set on openclaw either, so not carried over). `claws-auth` holds only rotating provider credentials, exactly two keys: `CLAUDE_CODE_OAUTH_TOKEN`, `CLAWS_CODEX_AUTH_JSON`. **`claws-auth` must never be committed, SOPS-encrypted or otherwise** — it is created imperatively (`kubectl create secret generic claws-auth --from-literal=... -n default`) and is the one Secret the pod itself is allowed to rewrite. `claws-config` may be supplied as a SOPS-encrypted `apps/claws/claws-config.enc.yaml` (recipient already in `.sops.yaml`; Flux decrypts everything under `./apps`) added to `apps/claws/kustomization.yaml`, or imperatively. Neither is created by this repo; both are `optional: true` in `envFrom` so the StatefulSet reconciles green with either or both absent. `CLAWS_ACTIVATION_STATE` and the `CLAWS_OIDC_*` keys must **not** go in either — the manifest's explicit `env:` entries shadow `envFrom`.

**Two GitHub App keys, both in git.** `claws-github-app` (`apps/claws/github-app.enc.yaml`, SOPS-encrypted under the age recipient already in `.sops.yaml`, single key `private-key.pem`) holds the **St-John-Software** App, id **3408744**, projected read-only at `0440` (readable under `fsGroup: 1000`) to `/etc/claws/github-app/private-key.pem` — the path `CLAWS_GITHUB_APP_PRIVATE_KEY_PATH` in `claws-config` points at, so renaming the mount breaks App auth. `claws-github-app-stjohnb` (`apps/claws/github-app-stjohnb.enc.yaml`, same recipient and key name) holds the **second** App, id **3408918**, used for the `stjohnb` owner, projected the same way at `/etc/claws/github-app-stjohnb/private-key.pem`. There is **no env var** for the second one — claws' `getCredentialsForOwner()` in `src/github-app.ts` reads `githubOwnerAppCredentials.stjohnb.{appId,privateKeyPath}` from `config.json` on the PVC and only falls back to the global App when both are absent. **The data-migration step in claws' `docs/k8s-cutover.md` § "Data migration" copies `config.json` verbatim, so after the `tar | kubectl exec` copy that entry must be rewritten from `/home/brendan/.claws/stjohnb-github-app.pem` to `/etc/claws/github-app-stjohnb/private-key.pem` (keeping `appId: 3408918`), then the pod restarted** — `githubOwnerAppCredentials` is read at config load. Without the rewrite every `stjohnb/*` repo fails with `[github-app] No credentials configured for owner stjohnb` or an ENOENT on the missing file. The St-John-Software key replaced the hand-seeded, not-in-git Secret `github-app-credentials` (key `privateKey`), which was deliberately never a manifest resource here — declaring an already-populated imperative Secret risks Flux SSA resetting its `.data`, the way an empty `authentik-secrets` manifest would. **A cluster rebuild therefore needs no hand-seeding step for either App key; only `claws-auth` remains imperative.**

**Credential rotation without a PR.** `/claude-auth` persists a refreshed `CLAUDE_CODE_OAUTH_TOKEN` to `~/.claws/env` on the PVC, and that file wins over the Secret on the next boot (`loadEnvFile()` in claws' `src/env-file.ts`). Codex has no such path yet: `~/.codex/auth.json` is rewritten from `CLAWS_CODEX_AUTH_JSON` on every boot, so a rotated ChatGPT refresh token is lost on restart. The `claws-staging` ServiceAccount and `claws-staging-auth` Role (`apps/claws/rbac.yaml`, `get`/`patch` on `resourceNames: [claws-auth]`) exist so claws can write the rotated value straight back into the Secret; the write must use the projected SA token (`--server https://kubernetes.default.svc --token "$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" --certificate-authority /var/run/secrets/kubernetes.io/serviceaccount/ca.crt`) rather than `~/.kube/config`, which the entrypoint overwrites from `CLAWS_KUBECONFIG`. Until that lands in the claws repo, the interim rotation is `kubectl exec -it claws-staging-0 -- codex login` then re-applying `claws-auth` imperatively — never a PR.

The traffic cutover to production (deleting `endpoints.yaml`, adding `selector: {app: claws}` to `service.yaml`) is deliberately not done yet. Runs with `CLAWS_ACTIVATION_STATE: verify-only`.

**OIDC**: Claws staging is configured for Authentik native OIDC. The deployment sets `CLAWS_OIDC_CLIENT_ID=claws`, `CLAWS_OIDC_BASE_URL=https://auth.home.bstjohn.net`, `CLAWS_OIDC_APPLICATION_SLUG=claws`, `CLAWS_OIDC_REDIRECT_URI=https://claws-staging.home.bstjohn.net/auth/callback`, and reads `CLAWS_OIDC_CLIENT_SECRET` from `authentik-secrets` (populated by migration `0004`). **No** Traefik ForwardAuth annotation is used — claws handles authentication natively, and Bearer-token callers continue to work through the app itself rather than an ingress bypass. The production `claws.home.bstjohn.net` host is Git-managed in this repo as a `Service`/`Endpoints`/`Ingress` proxy, but its backend remains external at `192.168.0.73:3000`; only the staging deployment itself runs in-cluster from this repo. The Authentik blueprint registers four redirect URIs — `claws.home.bstjohn.net` and `claws-staging.home.bstjohn.net` plus their `.ext.` siblings (#1109). `CLAWS_OIDC_REDIRECT_URI` is the fixed fallback and points at the home host, but `CLAWS_OIDC_HOST_MAP=claws-staging.ext.bstjohn.net=https://auth.ext.bstjohn.net` (claws#2841) makes claws resolve the Authentik base URL and `redirect_uri` per request from `X-Forwarded-Host`, so an `.ext.` login authenticates against `auth.ext.bstjohn.net` and lands back on `.ext.`. The map is a strict allow-list — an unmapped or spoofed `Host` falls through to the fixed pair, which is what stops it being an open redirect, so only hosts this pod actually serves belong in it. The production `claws.ext.bstjohn.net` process is external at `192.168.0.73:3000` and its `CLAWS_OIDC_HOST_MAP` is set on that host, not from this repo. Access is restricted to the `infra` group.

**Image updates are automatic.** `ghcr.io/st-john-software/claws` uses date-versioned tags (`vYYYY-MM-DD.N`) that GHCR periodically prunes; a pinned stale tag used to break the pod with `ErrImagePull`/`ImagePullBackOff` and needed a hand-edited PR (#477→#502, #504→#509, #545). Since #1034 the claws repo's Release workflow dispatches `.github/workflows/update-claws-staging.yml` after each image push, which rewrites the tag across `apps/claws/*.yaml` and opens/updates a single PR on `automation/bump-claws-staging` (labelled `dependencies,auto-bump`) for Claws' auto-merger. Tracking latest keeps the pinned tag inside GHCR's retention window, so pruning no longer breaks the pod. Do not "fix" pruning by making the package public: the owner explicitly wants org-built images to stay private while the org moves away from GitHub; solve pull auth or image publication instead.

### Homepage Per-Group Dashboards (#1079)

`home.bstjohn.net` is a single hostname, but two Homepage dashboards run behind it: `apps/homepage/config/services.yaml` is the full dashboard (all sections, all apps), and `apps/homepage/config-limited/services.yaml` is a trimmed, Apps-only dashboard shared by everyone else. `homepage-router` (nginx) sits in front of both Homepage Deployments and picks which one to proxy to based on whether the `X-authentik-groups` header — injected by Authentik's ForwardAuth and unforgeable from outside — contains `infra`.

**Admin preview (#1095).** The full dashboard's Infrastructure group has a "Shared dashboard" tile pointing at `https://home.bstjohn.net/preview/limited`. For a user whose groups include `infra`, `homepage-router` answers that path by setting a host-only cookie `homepage_view=limited` (1 hour, `HttpOnly`, `Secure`) and redirecting to `/`; while the cookie is present it proxies the admin to `homepage-limited` instead, with an nginx `sub_filter` banner injected before `</body>` linking to `/preview/exit`, which clears the cookie. The cookie is consulted only when the group check already passed, so it is inert for everyone else, and the limited config files carry no admin-only links. Because the cookie is per-host, every `home.bstjohn.net` tab shows the preview until you exit. The `@preview` location sends `Accept-Encoding: ""` upstream because `sub_filter` cannot rewrite a gzip body. The server block also sets `absolute_redirect off;`: nginx would otherwise rewrite the `/preview/*` redirects to `http://home.bstjohn.net:8080/` — its own listen port and the plaintext scheme Traefik hands it — which is unreachable from a browser (#1097). Any future redirect added to this router inherits that requirement.

Homepage runs `ghcr.io/gethomepage/homepage:v2.1.2`. Since upstream v1.0 it validates the HTTP `Host` header against `HOMEPAGE_ALLOWED_HOSTS` and returns **400** for anything not listed, on every path including `/api/healthcheck`. The allowlist therefore has to cover all three callers: `home.bstjohn.net` (Traefik ingress), `homepage:3000` (the Gatus check in `apps/gatus/config.yaml`), and the pod's own IP, injected via a downward-API `MY_POD_IP` env var so the kubelet's probes — which connect to the pod IP — are accepted. Missing the pod IP is what stalled the v2 rollout in #942: the startup probe got 400s, the container restart-looped, and the Flux `apps` Kustomization reported `HealthCheckFailed`. Homepage's own built-in auth (upstream v2.0) stays disabled — access is gated by the Authentik ForwardAuth middleware on the ingress instead. See [authentik.md](authentik.md).

### Homepage ISR Cache Warm-Up

The `gethomepage/homepage` image builds with an empty `config/` directory (upstream `Dockerfile`: `RUN mkdir config` then `pnpm run build`), so Next.js prerenders `/` at Docker build time from the upstream skeleton (`src/skeleton/services.yaml` — "My First Group", "My Second Group", "My Third Group") and ships it as `/app/.next/server/pages/en.html`. `prerender-manifest.json` records `initialRevalidateSeconds: false`, so that stale HTML is served on **every** request until something calls the on-demand ISR endpoint `/api/revalidate`. The only upstream trigger is a client-side `localStorage` hash mismatch, which requires a prior visit — so the first load after each pod start rendered the skeleton groups before client-side SWR replaced them (#935).

`apps/homepage/deployment.yaml` therefore carries a `postStart` lifecycle hook that polls `http://127.0.0.1:3000/api/revalidate` (up to 60 × 1s) to regenerate the page from the mounted ConfigMap before the kubelet starts probes or adds the pod to the Service endpoints. `127.0.0.1:<port>` is hardcoded as always-allowed in Homepage's host-validation middleware, so the hook is unaffected by `HOMEPAGE_ALLOWED_HOSTS`. The hook always exits 0 — a failing `postStart` hook kills the container. Worst-case 60s plus the 180s `startupProbe` budget stays inside Flux's 5-minute health-check window.

This recurs on every pod roll, and `apps/homepage/kustomization.yaml` sets `disableNameSuffixHash: false`, so every Homepage config change rolls the pod. Do not remove the hook and do not remove the name-suffix hash. The behaviour is unchanged between v0.10.x and v2.x, so the hook survives upgrades — but if Homepage's own built-in auth is ever enabled (`HOMEPAGE_AUTH_ENABLED`), `/api/revalidate` stops being a public path and the hook degrades to a harmless no-op that must be revisited.

### Planned: Overseerr + Plex removal (#798 — decided, not started)

The owner has decided to remove `apps/plex/` and `apps/servarr/overseerr/` in favour of Jellyfin and Jellyseerr, which are already deployed side by side with them. This has **not** been executed in this repo as of 2026-08-15 — Plex and Overseerr are both still present and listed in `apps/kustomization.yaml` — so don't assume either is gone, and don't propose new Plex/Overseerr-specific features without checking whether removal work has since started.

**Hard sequencing constraint for whoever picks this up**: the owner explicitly wants an automated migration of the Overseerr request backlog into Jellyseerr *before* Overseerr is deleted — a two-PR shape (migration lands and is verified first; only then does a second PR delete Plex/Overseerr and repoint Jellyfin's `truenas-gate` wake-page entry, which today belongs to Plex). Overseerr and Jellyseerr expose the same `/api/v1` request surface, but Jellyseerr's API has no way to create or restore a *pending* request — anything migrated lands pre-approved and is pushed to Sonarr/Radarr immediately. Whoever implements this must decide how to handle that gap (carry it as an accepted consequence, or filter pending requests out) rather than silently dropping it.

**How to apply**: treat Plex and Overseerr as scheduled for removal, not as a stable long-term architecture — but don't remove them proactively either, since the request-migration precondition above hasn't been built yet.

### Image Pinning

All container images are pinned to specific version tags — never `:latest`. This ensures reproducible deployments and enables version rollback. Renovate automates update PRs for both Helm charts and container images. The CI Trivy scan validates changed images for CRITICAL CVEs; private images (e.g., `ghcr.io/st-john-software/*`) are skipped when authentication is unavailable.

### Priority Classes

All deployments are assigned a `priorityClassName` from `apps/priority-classes.yaml` to control eviction order under memory pressure:

| Priority | Value | Services |
|----------|-------|----------|
| `critical-infrastructure` | 1000000 | gatus, authentik-server, postgres (shared instance, see [postgres.md](postgres.md)), kube-prometheus-stack (Grafana + Prometheus) |
| `standard` | 500000 | homepage, immich, mealie, truenas-gate, authentik-worker, ollama, whisper, forgejo, claws (staging), tailnet-dns |
| `low-priority` | 100000 | servarr services, bin-scraper, arpwatch, jellyfin, navidrome, jellyseerr, seerr, plex, pve-exporter, forgejo-runner |

### Resource Limits

All deployments set explicit `resources.requests` and `resources.limits` for both CPU and memory. Typical ranges:

- Lightweight proxies: 5-50m CPU request, 200m CPU limit, 16-64 MB memory
- Standard services: 50-100m CPU request, 500m-1000m CPU limit, 256 MB - 1 GB memory
- Heavy workloads (Immich ML): 200m CPU request, 4000m CPU limit, 512 MB - 4 GB memory

CPU limits use Linux CFS bandwidth control — a container hitting its limit gets throttled (degraded performance), not killed like memory OOM. Mealie is pinned to 1000m CPU / 1Gi memory (up from 500m/256Mi) after node-reboot 502s/crash-loops were traced to 1-second probe timeouts combined with CPU throttling during image-upload processing — the probe would time out right when the throttled container was slowest to respond (PR #645). When a probe/resource combination causes flapping under load, prefer raising both the limit and the probe timeout together rather than just one. bin-scraper was raised the same way (500m/256Mi → 1000m/1Gi, probe timeouts 1s → 5s) after an unpinned `google-chrome-stable` rebuild pushed headless Chromium past the 256Mi limit and OOMKilled it on every boot scrape (#765); its probes also moved from `/health` (a data-freshness signal that returns 503 until the first successful scrape, so it fails on every fresh pod) to `/version` (always-200, unauthenticated), leaving `/health` monitored externally by Gatus. Gatus's root-URL check was later moved to `/version` too, and a `/auth/status` check added, because every UI route is now behind Authentik OIDC (issue #790) and returns 401 to header-less monitors.

### Termination Grace Periods

Database and stateful workloads use extended `terminationGracePeriodSeconds` (default is 30s) to allow clean shutdown (WAL flush, checkpoint, connection draining):

| Workload | Grace Period | Reason |
|----------|-------------|--------|
| Immich pod (contains pgvecto-rs) | 90s | PostgreSQL WAL flush + vector index serialization |
| Authentik PostgreSQL | 90s | Clean checkpoint and connection draining |

### Service Account Tokens

Nearly every workload sets `automountServiceAccountToken: false` — most app containers (servarr, Immich, Mealie, Transmission, Forgejo, Claws staging, etc.) never call the Kubernetes API, so a compromised container shouldn't be handed API credentials by default (#148). Headlamp and the `kube-prometheus-stack` components are the intentional exceptions — both genuinely need the Kubernetes API and mount the token via their Helm chart defaults. When adding a new service, set this to `false` unless the workload actually calls the K8s API.

### enableServiceLinks

Almost all Deployments/StatefulSets/CronJobs set `enableServiceLinks: false` — this is a fleet-wide convention (originally added for Immich, see [docs/immich.md](immich.md)), not an Immich-specific setting. Without it, Kubernetes injects one `{SVC}_SERVICE_HOST`/`_PORT` env var pair per Service visible to the pod — 200+ vars in this cluster — which is pure noise and can collide with an app's own port env vars (#149). No service here relies on service-link env vars for discovery; everything uses DNS. Set it to `false` on any new workload.

### Pod Hostname (Jellyfin)

`apps/jellyfin/deployment.yaml` is the one workload that sets `hostname:` on the pod spec. Jellyfin derives its advertised server name from `ServerConfiguration.ServerName`, falling back to the container's machine name when that is empty — and it *is* empty here, because the setup wizard never set it. Without a pinned hostname the name reported by `/System/Info/Public` (and shown in every client, DLNA renderer and UDP auto-discovery reply) was the pod name, so it changed on every rollout (#812). `hostname: jellyfin` fixes that declaratively, with no dependency on the `jellyfin-api-key` Secret or the `config-reconciler` sidecar. It deliberately is *not* the FQDN: the API server requires `spec.hostname` to be a single RFC 1123 label and rejects dots, and `kubeconform` will not catch a dotted value — it would pass CI and fail at Flux apply time. The public FQDN belongs in `JELLYFIN_PublishedServerUrl` and the ingress, where it already is. Other services don't need this — their display names come from their own config, not the machine name.

### PodDisruptionBudgets

`gatus` and `authentik-server` each have a `PodDisruptionBudget` (`minAvailable: 1`), and `kube-prometheus-stack` configures one for both Grafana and Prometheus via Helm values — covering the services whose loss during a `kubectl drain` would be most disruptive (uptime monitoring, SSO, dashboards/alerting). The PDB doesn't prevent eviction outright; it forces an operator running node maintenance to consciously override with `--force`/`--disable-eviction` instead of silently mass-evicting these in one drain (#146).

### Secrets

Never committed to Git. Created imperatively:

```bash
kubectl create secret generic my-secret --from-literal=key=value -n default
```

Known secrets (referenced in deployments): `gatus-secrets`, `transmission-wireguard`, `immich-db-secret`, `pve-exporter-secret`, `bin-scraper-mqtt`, `bin-scraper-gh-token`, `bin-scraper-session`, `grafana-admin-secret`, `grafana-slack-webhook`, `flux-slack-webhook`, `authentik-secrets`, `jellyfin-api-key`, `postgres-superuser`, `garden-db-secret`, `garden-session`.

A few secrets are committed as SOPS-encrypted `*.enc.yaml` instead, since Flux needs them present at reconcile time rather than pre-created imperatively: `ghcr-pull` (`apps/ghcr-pull-secret.enc.yaml`, see [ghcr-auth.md](ghcr-auth.md)) and `bin-scraper-address` (`apps/bin-scraper/address-secret.enc.yaml`, supplies `SCRAPER_POSTCODE`/`SCRAPER_ADDRESS_MATCH`/`REPORTER_POSTCODE`/`REPORTER_ADDRESS_MATCH` so the scraper's postcode and address-match string aren't hardcoded in a tracked file). **`SCRAPER_ADDRESS_MATCH` must stay set**: the upstream scraper falls back to picking a random address option from the council site's dropdown when it's unset, which can land on a non-selectable placeholder and fail the scrape with a `waitForSelector` timeout — this caused a real outage (#906) before the key was added to the deployment (#907).

## Configuration

### Network

| Purpose | Address |
|---------|---------|
| Cluster node | 192.168.0.251 |
| Tailscale IP | 100.78.7.18 |
| NAS (NFS) | 192.168.0.128 |
| Proxmox host | 192.168.0.200 |
| Home Assistant | 192.168.0.89 |
| UniFi gateway | 192.168.0.1 |
| Awtrix (kitchen) | 192.168.0.30 |
| Awtrix (office) | 192.168.0.160 |
| Claws host | 192.168.0.73 |

### Domains

| Domain | Resolves to | Use |
|--------|-------------|-----|
| `*.home.bstjohn.net` | 192.168.0.251 (LAN DNS) / 100.78.7.18 (tailnet split DNS) | LAN access; Tailscale split DNS routes to the in-cluster resolver, subnet router as fallback |
| `home.bstjohn.net` | 192.168.0.251 | Homepage dashboard (apex) |
| `*.ext.bstjohn.net` | 100.78.7.18 | Tailnet access direct to the `k3s` node's Traefik (no subnet router) |
| `ext.bstjohn.net` | 100.78.7.18 | Homepage dashboard over the tailnet (apex) |

### CI Configuration

CI is defined in `.github/workflows/ci.yml` and covers the entire monorepo (both `clusters/` and `apps/`). See [infrastructure-overview.md](infrastructure-overview.md) for full CI job details.

A separate workflow (`.github/workflows/update-bin-scraper.yml`) handles automated image updates for the bin-scraper service. It is triggered via `workflow_dispatch` (the bin-scraper repo's Release workflow dispatches it with `gh workflow run`, authorized by the org-level `FLEET_INFRA_VERSION_BUMP` PAT — see [infrastructure-overview.md](infrastructure-overview.md)), validates the tag format (`YYYYMMDD-N-HASH`), updates `apps/bin-scraper/deployment.yaml` in place, and opens a PR on an `automation/bump-bin-scraper-<tag>` branch labelled `dependencies,auto-bump`. `.github/workflows/update-claws-staging.yml` follows the same handshake for `claws-staging`, dispatched by the claws repo's Release workflow, but force-updates a single fixed branch (`automation/bump-claws-staging`) instead of a per-tag branch, since claws releases on every push to `main`. These are the only GitOps automation in the repo that bypasses the manual PR review requirement: the `auto-bump` label marks the PR for Claws' auto-merger, which merges it once CI passes, instead of native GitHub auto-merge.

## Subsystem Documentation

- [OVERVIEW.md](OVERVIEW.md) — Main entry point for the fleet-infra monorepo
- [Monitoring Stack](monitoring.md) — Prometheus, Grafana, PVE exporter, dashboards
- [Servarr Media Stack](servarr.md) — Transmission (WireGuard VPN), Sonarr, Radarr, Prowlarr, Bazarr, Overseerr
- [TrueNAS Gate](truenas-gate.md) — Availability proxy for NAS-dependent services
- [Immich](immich.md) — Photo management with ML, PostgreSQL, and Valkey
- [Authentik SSO](authentik.md) — ForwardAuth middleware, protected services, Grafana proxy auth
- [Flux Notifications](notifications.md) — Slack alerting for source changes, errors, and Helm upgrades

## Service URL Reference

| Service | URL | Type |
|---------|-----|------|
| Homepage | home.bstjohn.net | Deployed |
| Grafana | grafana.home.bstjohn.net | Helm (monitoring) |
| Prometheus | prometheus.home.bstjohn.net | Helm (monitoring) |
| Gatus | gatus.home.bstjohn.net | Deployed |
| Immich | immich.home.bstjohn.net | Deployed (gated) |
| Mealie | mealie.home.bstjohn.net | Deployed |
| Bin Scraper | bin-scraper.home.bstjohn.net | Deployed |
| Garden | garden.home.bstjohn.net | Deployed (shared Postgres, local-path photo volume, Prisma migrations via initContainer) |
| Transmission | transmission.home.bstjohn.net | Deployed (gated, paused at 0 replicas) |
| Sonarr | sonarr.home.bstjohn.net | Deployed |
| Radarr | radarr.home.bstjohn.net | Deployed |
| Prowlarr | prowlarr.home.bstjohn.net | Deployed |
| Bazarr | bazarr.home.bstjohn.net | Deployed |
| Overseerr | overseerr.home.bstjohn.net | Deployed |
| Jellyfin | jellyfin.home.bstjohn.net | Deployed |
| Navidrome | music.home.bstjohn.net | Deployed (SSO on the UI; /rest + /share bypass ForwardAuth) |
| Music Assistant | music-assistant.home.bstjohn.net | External proxy (HAOS add-on on 192.168.0.89:8095) |
| Jellyseerr | jellyseerr.home.bstjohn.net | Deployed |
| Seerr | seerr.home.bstjohn.net | Deployed (preview) |
| Home Assistant | home-assistant.home.bstjohn.net | External proxy |
| Plex | plex.home.bstjohn.net | Deployed (`k3s`, soft NFS media mount, gated via truenas-gate) |
| Wake NAS | wake.home.bstjohn.net | Deployed (truenas-gate wake page, always reachable) |
| Authentik | auth.home.bstjohn.net | Multi-deployment (SSO provider) |
| Headlamp | dashboard.home.bstjohn.net | Helm release |
| Forgejo | git.home.bstjohn.net | Deployed (15.0.5, push-mirrors to GitHub, Actions enabled, in-cluster runner; backups: [forgejo-backups.md](forgejo-backups.md)) |
| Arpwatch | — | Deployed (no ingress, hostNetwork) |
| Containerd GC (main node) | — | CronJob `containerd-gc` (daily 04:00, 300s deadline — completes in ~3s) |
| Containerd GC (k3s-nas) | — | CronJob `containerd-gc-storage` (daily 04:30, 1800s deadline, backoffLimit: 1 — HDD-backed node may have image backlog; resolves `crictl` via explicit host PATH — NixOS) |
| Admission error reaper | — | CronJob `admission-error-reaper` on `k3s` (every 5 min, 120s deadline — deletes GPU admission-race pod tombstones; see [gpu-k3s.md](gpu-k3s.md)) |
| Config Backup (servarr) | — | CronJob `config-backup` on `k3s-nas` (nightly 02:00 Europe/London, SQLite-consistent backup of the four servarr config PVCs; see [config-backups.md](config-backups.md)) |
| Config Backup (players) | — | CronJob `config-backup-players` on `k3s` (nightly 01:00 Europe/London, same script, covers `plex-config`, `jellyfin-config`, `jellyseerr-config`, `seerr-config`) |
| Forgejo backup (local) | — | CronJob `forgejo-backup` (daily 02:30, `forgejo dump` → `forgejo-backups` local-path PVC, 14 retained) |
| Forgejo backup (offsite) | — | CronJob `forgejo-backup-offsite` (daily 03:00, copies new dumps to NFS `/media/backups/forgejo`, 14 retained) |
| Ollama | — | Deployed (GPU node, in-cluster only — no ingress) |
| Whisper | — | Deployed (GPU node, in-cluster only — audio transcription API, port 9000) |
| Awtrix (kitchen) | awtrix-kitchen.home.bstjohn.net | External proxy |
| Awtrix (office) | awtrix-office.home.bstjohn.net | External proxy |
| Claws | claws.home.bstjohn.net | External proxy |
| Claws (staging) | claws-staging.home.bstjohn.net | StatefulSet (containerized staging, 50Gi `local-path` PVC) |
| Proxmox | proxmox.home.bstjohn.net | External proxy (IngressRoute) |
| UniFi | unifi.home.bstjohn.net | External proxy (IngressRoute) |

*(gated) = routed through truenas-gate for availability handling*
