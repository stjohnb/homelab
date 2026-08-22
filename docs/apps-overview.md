# Applications Overview

Application manifests for a single-node k3s homelab cluster, living in the `apps/` directory of the fleet-infra monorepo. Deployed via Flux CD GitOps to the `default` namespace. For the main entry point, see [OVERVIEW.md](OVERVIEW.md).

The cluster runs 30+ services across media automation, home automation, monitoring, networking, and productivity.

## Architecture

### GitOps Flow

```
Feature Branch → Pull Request → CI Validation → Merge → Flux Reconciliation → Cluster
```

- **CI checks** (all blocking): YAML lint, kustomize build, kubeconform validation, kubesec security scan, Trivy image vulnerability scan (CRITICAL CVEs only, changed images), secret detection, kustomization completeness (verifies all service directories are listed in parent kustomization.yaml), Renovate config validation
- **Kustomize diff comment**: CI posts a PR comment with a unified diff of rendered manifests (base vs PR branch), auto-updated on each push. Non-blocking (`continue-on-error`).
- **Flux health checks**: After applying manifests, Flux verifies critical resources reach Ready status within 5 minutes. Failures trigger Slack notifications. Configured via `spec.healthChecks` on the `apps` Kustomization in `clusters/my-cluster/apps-kustomization.yaml`. Monitored: Deployments (`gatus`, `homepage`). The `kube-prometheus-stack` HelmRelease is intentionally excluded — its reconciliation on a single-node cluster routinely exceeds the 5-minute timeout while in 'InProgress' state, producing noisy false-positive Slack alerts. Actual HelmRelease failures are still reported via the `slack-errors` alert, which watches it directly. Intentionally excluded: Immich (depends on NFS from the NAS, which is not always on — would produce false-positive alerts every minute), the standalone `pve-exporter` (a peripheral metric collector with external dependencies).
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
├── jellyseerr/                 # Media request UI for Jellyfin (jellyseerr.home.bstjohn.net)
├── seerr/                      # Seerr preview with native Authentik OIDC, beside jellyseerr (seerr.home.bstjohn.net)
├── truenas-gate/               # Nginx proxy for NAS-dependent services (see docs/truenas-gate.md)
│
├── arpwatch/                   # ARP monitoring with Slack alerts (hostNetwork)
├── mealie/                     # Recipe manager
├── vaultwarden/                # Password manager (Bitwarden-compatible, no ForwardAuth — native OAuth)
├── bin-scraper/                # Council bin collection scraper → MQTT → HA
│
├── authentik/                  # SSO provider (ForwardAuth middleware)
├── headlamp/                   # Kubernetes web UI dashboard (Helm)
│
├── forgejo/                    # Git forge (git.home.bstjohn.net) + 2 backup CronJobs — see docs/forgejo.md, docs/forgejo-mirroring.md
├── forgejo-runner/             # Forgejo Actions runner (dind)
├── datasette/                  # SQLite data explorer (datasette.home.bstjohn.net)
├── open-webui/                 # AI chat UI (chat.home.bstjohn.net) — resource name unchanged
│
├── home-assistant/             # External service proxy (192.168.0.89)
├── claws/                      # External proxy (192.168.0.73:3000) + containerized staging deployment
├── containerd-gc/              # CronJobs: daily image GC (main 04:00 300s limit; k3s-nas 04:30 1800s limit)
├── config-backup/              # CronJobs: nightly SQLite-consistent backup of the servarr (k3s-nas) and Plex/Jellyfin (k3s) config PVCs (see docs/config-backups.md)
├── ollama/                     # Deployed (GPU node, see docs/gpu-k3s.md) — in-cluster only (no ingress, accessed by open-webui via Service DNS)
├── whisper/                    # Deployed (GPU node, audio transcription API, port 9000) — in-cluster only (no ingress)
├── nvidia-device-plugin/       # HelmRelease (GPU node device plugin) + RuntimeClass (see docs/gpu-k3s.md)
├── plex/                       # Deployed (k3s since #800, soft NFS media mount) — ingress still routes via truenas-gate
├── awtrix/                     # External service proxy (192.168.0.30:80)
├── proxmox/                    # External service proxy (192.168.0.200:8006, IngressRoute)
└── unifi/                      # External service proxy (192.168.0.1:443, IngressRoute)
```

### Service Types

Services fall into three categories:

| Type | Pattern | Examples |
|------|---------|----------|
| **Deployed** | Full Deployment + Service + Ingress + PVC | immich, mealie, homepage, gatus, servarr/*, plex |
| **External proxy** | Endpoints + Service + Ingress (no pods) | home-assistant, awtrix, claws |
| **Helm release** | HelmRelease + HelmRepository CRDs | monitoring/kube-prometheus-stack, headlamp |
| **Multi-deployment** | Multiple Deployments + Services + Middleware | authentik (server, worker, postgresql) |
| **CronJob** | CronJob (privileged, no ingress) | containerd-gc, containerd-gc-storage, config-backup |

**External proxies** expose devices/VMs on the LAN through the cluster's ingress and TLS, using manually defined Endpoints pointing to static IPs.

**Proxmox and UniFi** use Traefik `IngressRoute` + `ServersTransport` (with `insecureSkipVerify`) instead of standard Ingress, because their backends serve self-signed HTTPS.

### Adding a Service to Kustomize

Every service directory must be listed in `apps/kustomization.yaml` under `resources:`. Each service directory has its own `kustomization.yaml` listing its manifests.

## Key Patterns

### TLS: Shared Wildcard Certificate

A single `Certificate` resource (`wildcard-home-cert.yaml`) covers `*.home.bstjohn.net` and `home.bstjohn.net`. All ingresses reference `secretName: wildcard-home-tls`.

**Never** add `cert-manager.io/cluster-issuer` annotations to ingresses or create per-service Certificate resources — this creates DNS pollution that breaks wildcard resolution (see [CLAUDE.md](../CLAUDE.md) for the full explanation).

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

The Immich PostgreSQL database is backed up via a CronJob (`immich-db-backup`) that runs `pg_dump --format=custom` every 6 hours (`0 */6 * * *`, Europe/London). Backups are written to `/mnt/SSD-POOL/media/backups/immich/` on the NFS media share, with the 14 most recent retained. Since the NAS is not always on, deadline-killed runs during a NAS outage (pod stays Pending, killed after 30 min by `activeDeadlineSeconds`) remain expected and are filtered from alerting — `failedJobsHistoryLimit: 1` keeps the job list clean. Any other non-zero exit is a real failure and pages, because the job verifies dump contents (row counts, TOC, size floor) rather than trusting `pg_dump`'s exit status alone. See [docs/immich.md](immich.md) for backup verification and restore procedures.

### TrueNAS Gate

Services whose ingresses route through `truenas-gate` — an nginx reverse proxy that shows a "wake the NAS" page when backends are unavailable instead of a raw error. Currently gated: Immich, Plex, Transmission. Plex's ingress still targets `truenas-gate` (not the `plex` Service directly) even though Plex now runs on the always-on node — that indirection is deliberate, not legacy cruft: it covers the window where a Plex pod is *restarted* while the NAS is asleep and gets stuck in `ContainerCreating` (a soft mount rescues a running pod, not a starting one). The gate also serves the wake page unconditionally at `wake.home.bstjohn.net`, since Plex and Jellyfin no longer fall through to it while the NAS sleeps. See [docs/truenas-gate.md](truenas-gate.md).

### Gatus Alerting for NFS-Dependent Services

Sonarr, Radarr, Bazarr, Immich, and Transmission are placed in a `media-services` group in `apps/gatus/config.yaml` with **no per-service Slack alerts** — this is deliberate, not an oversight (#93). A dedicated `NAS` endpoint carries the alert instead ("NAS is down — Sonarr, Radarr, Bazarr, Immich, and Transmission will also be unavailable") and acts as the sole canary for the group. The original ask was for Gatus to alert on these services during normal operation but suppress the alert specifically when the NAS is down (so an app-level crash — a bad Sonarr config, Immich's ML container OOMing — would still page while the NAS is up); Gatus has no built-in way to make one endpoint's alert conditional on another's status, so the group was left alert-free and NAS-down is treated as the explanation for the whole group being unreachable. Net effect: an app-level failure in one of these services while the NAS is healthy currently produces no Slack notification — known and accepted, not a target for automatic fixing without new Gatus capability. Jellyfin and Plex left this group in #800: they run on the always-on node behind a soft NFS mount, so a failure is real rather than expected NAS downtime, and both now alert to Slack ungrouped. The `NAS` check itself is a TCP probe against `192.168.0.128:2049` (NFS) — it proves the NFS listener is up, not that the ZFS pool imported successfully.

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

1. **ForwardAuth (8 services)** — Traefik intercepts requests and validates sessions with Authentik's embedded outpost. Protected ingresses add `traefik.ingress.kubernetes.io/router.middlewares: default-authentik-auth@kubernetescrd`. Services: Sonarr, Radarr, Prowlarr, Bazarr, Transmission, Grafana, Prometheus, Datasette.

2. **Native OIDC (11 services)** — Services handle authentication natively and redirect to Authentik's login flow. No ingress annotation needed. Services: Mealie (`OIDC_AUTH_ENABLED=true`), Open WebUI (OAuth2 callback), Jellyfin (via `jellyfin-plugin-sso`), Jellyseerr (configured in web UI), Headlamp, Proxmox, Bin Scraper, Claws, Forgejo, Seerr (`settings.json` written by the `oidc-init` initContainer), Home Assistant (provider wired but not yet consumed HA-side — pending vendoring of `auth_oidc` in `home-assistant-config`).

The ForwardAuth address uses FQDN `authentik-server.default.svc.cluster.local` because Traefik runs in its own namespace. The embedded outpost is declaratively configured in the blueprint — the `authentik_outposts.outpost` entry lists all 8 proxy providers by `!KeyOf` reference, ensuring provider-to-outpost attachment is version-controlled. Proxy providers, applications, users, groups, and per-app policy bindings are all configured declaratively via Authentik blueprints (`configmap-blueprints.yaml`), which define 8 ForwardAuth proxy providers (one per service), 8 proxy applications, 11 OIDC providers, 4 groups (`all-apps`, `media`, `home`, `infra`), 2 users, and 16 ForwardAuth policy bindings. Each application is bound to a category-specific group plus the `all-apps` fallback group using `policy_engine_mode: any`. Group memberships are fully declarative — manual changes in the Authentik UI are reverted on reconciliation. Gatus is intentionally excluded from ForwardAuth so that monitoring remains accessible during an Authentik outage. Grafana additionally uses `auth.proxy` for automatic user creation from Authentik sessions. See [docs/authentik.md](authentik.md) for the full architecture, blueprint configuration, access control model, protected service list, and security model.

### Ingress (Home Domain)

All services use `*.home.bstjohn.net` (LAN, 192.168.0.251) ingresses — no separate ext ingress needed. Tailscale devices resolve the same domain via public DNS and reach it through a subnet router advertising `192.168.0.0/24`; see [Remote access over Tailscale](infrastructure-overview.md#remote-access-over-tailscale).

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
- **Auth model**: Users log in via Authentik SSO (OIDC). Access is gated by membership in the Authentik `infra` group (bound to the `headlamp` application in `apps/authentik/configmap-blueprints.yaml`). After successful OIDC login, Headlamp's server uses its own ServiceAccount (`headlamp`, bound to the `read-only-cluster-viewer` ClusterRole) to call the Kubernetes API — all authenticated users share these read-only permissions. Per-user RBAC at the kube-apiserver level is not configured; adding it would require kube-apiserver `--oidc-*` flags on the k3s node.
- **OIDC secret**: `headlamp-oidc` Secret in `default` (keys: `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `OIDC_ISSUER_URL`, `OIDC_SCOPES`). Populated by `migrations/0011-headlamp-oidc-secret.sh`; the live cluster was rekeyed from the original lowercase camelCase names by `migrations/0012-headlamp-oidc-rekey.sh`. The Helm chart mounts this Secret via `envFrom: secretRef` and the container args reference the keys as `$(OIDC_CLIENT_ID)` etc. — uppercase names are required. Client secret also lives in `authentik-secrets.HEADLAMP_OIDC_CLIENT_SECRET` for the Authentik blueprint to reference via `!Env`.
- **Legacy fallback**: `migrations/0007-headlamp-token.sh` / `headlamp-token` secret remain in place. They are unused by the normal OIDC flow but preserved so users can still paste a token via the login screen if Authentik is down.
- **Session TTL workaround**: `config.sessionTTL: null` overrides the chart's default value that generates a `-session-ttl` flag the binary doesn't recognize (chart bug).
- **Key values**: `clusterRoleBinding.create: false` (prevents the chart's default cluster-admin binding)
- **Install/upgrade timeouts**: `install.timeout: 10m` and `upgrade.timeout: 10m` — explicitly set (vs the Flux default 5m) as defence-in-depth against slow secret provisioning or image-pull races during upgrades. Note: a `Stalled` (`RetriesExceeded`) HelmRelease does not self-recover — bumping the spec generation (e.g., by changing these values) causes helm-controller to reset the failure counter and retry.
- **Why apps layer, not infrastructure**: Headlamp was originally in `infrastructure/` but was moved to `apps/` because infrastructure uses `wait: true` — a Headlamp failure cascaded via the `dependsOn` chain and blocked all cluster reconciliation. Only foundational components (cert-manager, godaddy-webhook, traefik) should be in the infrastructure layer.

### Arpwatch Notifications

Arpwatch monitors ARP traffic on the host network to detect new devices and address changes. It uses a dedicated container image (`ghcr.io/st-john-software/arpwatch`) built by `.github/workflows/build-arpwatch.yml` with calver tags (`vYYYY-MM-DD.N`). Renovate tracks and bumps the tag automatically. The image bundles arpwatch, jq, curl, and the full IEEE OUI vendor database (`ethercodes.dat`, downloaded from `standards-oui.ieee.org` at build time via awk) — this ensures vendor lookups work correctly without relying on Alpine's bundled stub. It runs with `-F` (foreground) mode which keeps the process as PID 1 while still invoking sendmail for alerts. The sendmail binary is replaced by a symlinked shell script (`notify-slack.sh` from a ConfigMap) that formats alerts as Slack messages using `jq` for JSON construction. The Slack webhook URL comes from the shared `gatus-secrets` secret. Requires `NET_RAW` capability for ARP monitoring (not fully privileged). The script silently drops alerts where the source IP is `0.0.0.0` — these are normal ARP probes (RFC 5227) and DHCP discovery packets that generate harmless "flip flop" noise when multiple devices probe the network.

### Secret Migration Jobs

`migrations/` (at the repository root, deployed via a dedicated Flux Kustomization) contains a single idempotent Job that auto-generates secret values and writes them into the `authentik-secrets` Secret. This avoids hardcoding generated secrets in Git while keeping them reproducible across fresh cluster installs.

The `migrations` Kustomization depends on `infrastructure` (not `config`) and runs in parallel with the `config` layer. The `apps` Kustomization depends on both `config` and `migrations`, so application pods only start after secrets are ready. See [infrastructure-overview.md](infrastructure-overview.md#reconciliation-layers) for the full dependency chain.

**Migration scripts** (each targets a distinct key in `authentik-secrets`):

| Script | Key populated |
|--------|--------------|
| `0001-authentik-secret-key.sh` | `AUTHENTIK_SECRET_KEY` |
| `0002-authentik-bootstrap-token.sh` | `AUTHENTIK_BOOTSTRAP_TOKEN` |
| `0003-pg-pass.sh` | `PG_PASS` |
| `0004-oidc-client-secrets.sh` | All OIDC client secrets in `authentik-secrets`: `MEALIE_`, `OPEN_WEBUI_`, `JELLYFIN_`, `JELLYSEERR_`, `HEADLAMP_`, `PROXMOX_`, `BIN_SCRAPER_`, `CLAWS_`, `FORGEJO_`, `SEERR_`, `HOME_ASSISTANT_` (each suffixed `_OIDC_CLIENT_SECRET`) |
| `0006-fix-transmission-pvc-access-mode.sh` | Migrates Transmission PVC access mode |
| `0007-headlamp-token.sh` | `headlamp-token` (ServiceAccount token) |
| `0011-headlamp-oidc-secret.sh` | `headlamp-oidc` Secret (OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, OIDC_ISSUER_URL, OIDC_SCOPES) |
| `0012-headlamp-oidc-rekey.sh` | Renames `headlamp-oidc` keys from lowercase camelCase to uppercase env-var style; restarts `headlamp` deployment |
| `0014-vaultwarden-admin-token.sh` | `vaultwarden-admin` Secret (key: `admin_token`, 64 random chars) |
| `0017-forgejo-runner-secret.sh` | `forgejo-runner-secret` Secret (keys: `uuid`, `token`) — registers the forgejo-runner via `forgejo-cli` exec, see [docs/forgejo-actions.md](forgejo-actions.md) |
| `0019-forgejo-oidc-auth-source.sh` | Creates the Forgejo `authentik` OAuth2 auth source via `forgejo admin auth add-oauth` exec, then restarts `deployment/forgejo` so the new source is served — see [docs/forgejo.md](forgejo.md#authentik-sso) |
| `0020-bin-scraper-session-secret.sh` | `bin-scraper-session` Secret (`session-secret` key) |

**Job design:**
- A single Job (`migration-runner`) runs `run-migrations.sh` which orchestrates numbered scripts in lexicographic order.
- **State tracking**: Execution state is persisted in a ConfigMap (`migration-state`, key per script, value like `completed:<timestamp>`). Completed scripts are never re-run; failed scripts are retried on the next invocation.
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

**Adding a new migration:** Add a new script `migrations/NNNN-key-name.sh` and add it to the `configMapGenerator` in `migrations/kustomization.yaml`. The runner picks it up automatically in lexicographic order. **For a new Authentik OIDC client secret, do not add a script** — append the key name to the `KEYS` array in `migrations/0004-oidc-client-secrets.sh`. It is numbered `0004` rather than at the end of the sequence because `0011` and `0019` read keys it generates and the runner executes in lexicographic order.

### Claws Staging

`apps/claws/` contains both an external proxy (`claws.home.bstjohn.net` → `192.168.0.73:3000`) and a containerized staging deployment (`claws-staging.home.bstjohn.net`). Both share the same directory.

The staging deployment uses `strategy: type: Recreate` because it has a `ReadWriteOnce` `local-path` PVC (`claws-staging-data`, 1 Gi). `Recreate` is required when a volume cannot be mounted by two pods simultaneously — the old pod must fully terminate before the new one starts. Runs with `CLAWS_ACTIVATION_STATE: verify-only`.

**OIDC**: Claws staging is configured for Authentik native OIDC. The deployment sets `CLAWS_OIDC_CLIENT_ID=claws`, `CLAWS_OIDC_BASE_URL=https://auth.home.bstjohn.net`, `CLAWS_OIDC_APPLICATION_SLUG=claws`, `CLAWS_OIDC_REDIRECT_URI=https://claws-staging.home.bstjohn.net/auth/callback`, and reads `CLAWS_OIDC_CLIENT_SECRET` from `authentik-secrets` (populated by migration `0004`). **No** Traefik ForwardAuth annotation is used — claws handles authentication natively. The production `claws.home.bstjohn.net` host is a static external proxy pointing to `192.168.0.73:3000` and is configured out-of-band; only the staging deployment is managed in this repo. All four redirect URIs (staging home, staging ext, production home, production ext) are registered in the Authentik blueprint. Access is restricted to the `infra` group.

**Known recurring issue**: `ghcr.io/st-john-software/claws` images use date-versioned tags (`vYYYY-MM-DD.N`) that are periodically pruned from GHCR. When the pinned tag is pruned, the pod enters `ErrImagePull`/`ImagePullBackOff`. The fix is to manually bump the image tag in `apps/claws/deployment-staging.yaml` and merge a PR. This has occurred three times (#477→#502, #504→#509, #545). The durable fix would be Flux Image Automation (`ImageRepository` + `ImagePolicy` + `ImageUpdateAutomation` targeting `deployment-staging.yaml`), which would auto-open a bump PR on each new build.

### Vaultwarden (Password Manager)

`apps/vaultwarden/` is a self-hosted Bitwarden-compatible password manager (Rust-based Vaultwarden server). Key design decisions:

- **No Authentik ForwardAuth** — Bitwarden clients authenticate via their own OAuth-style flow on `/identity/connect/token`. Adding the `default-authentik-auth@kubernetescrd` middleware would cause Traefik to return 302 redirects that the Bitwarden CLI and mobile apps cannot follow, producing cryptic auth failures.
- **Registration is closed** — `SIGNUPS_ALLOWED=false`. Because Vaultwarden deliberately sits outside the Authentik ForwardAuth chain (see above), the ingress is the only gate in front of it, and it is reachable from every host on `192.168.0.0/24` and from the tailnet. Leaving self-registration open would let any LAN or tailnet client create an authenticated account on the vault service. `INVITATIONS_ALLOWED=true` is the onboarding path: invite from the admin panel at `https://vaultwarden.home.bstjohn.net/admin` using the token in the `vaultwarden-admin` Secret (generated by migration `0014-vaultwarden-admin-token.sh`). Admin-panel invites work regardless of `SIGNUPS_ALLOWED`; `INVITATIONS_ALLOWED` additionally lets an organisation owner invite an address that has no account yet. Existing accounts are unaffected by the flag — it only gates `POST /identity/accounts/register`.
- **`strategy.type: Recreate`** — required because the PVC is `ReadWriteOnce` and Vaultwarden uses SQLite (single-writer). `RollingUpdate` would deadlock waiting for the new pod to mount a volume still held by the old pod.
- **`local-path` storage** — data is SQLite + attachments, which must be accessible even when the NAS is offline (passwords are needed regardless of NAS state). 5 Gi PVC is sufficient for this use case.
- **`DOMAIN` env var** — must be the exact HTTPS URL clients connect to (`https://vaultwarden.home.bstjohn.net`, no trailing slash). Mismatch causes client registration and icon-fetch failures.
- **Admin token** — generated by migration `0014-vaultwarden-admin-token.sh` (64 random alphanumeric chars). Stored as plaintext in the `vaultwarden-admin` Secret (not Argon2-hashed) because the `alpine/k8s` migration runner image does not include the argon2 CLI; Vaultwarden emits a startup warning but continues to accept plaintext.

### Homepage Dual-Listing

Overseerr is intentionally listed in both the "Apps" and "Servarr" sections of the Homepage dashboard (`homepage/config/services.yaml`). This makes it discoverable for non-technical users in the main Apps section while also appearing in its logical Servarr group. Both entries have comments explaining the intentional duplication.

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
| `critical-infrastructure` | 1000000 | gatus, authentik-server, authentik-postgresql, kube-prometheus-stack (Grafana + Prometheus) |
| `standard` | 500000 | homepage, immich, mealie, vaultwarden, truenas-gate, authentik-worker, ollama, whisper, forgejo, claws (staging) |
| `low-priority` | 100000 | servarr services, bin-scraper, arpwatch, datasette, jellyfin, jellyseerr, seerr, open-webui, plex, pve-exporter, forgejo-runner |

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

Nearly every workload sets `automountServiceAccountToken: false` — most app containers (servarr, Immich, Mealie, Transmission, Forgejo, Vaultwarden, Claws staging, etc.) never call the Kubernetes API, so a compromised container shouldn't be handed API credentials by default (#148). Headlamp and the `kube-prometheus-stack` components are the intentional exceptions — both genuinely need the Kubernetes API and mount the token via their Helm chart defaults. When adding a new service, set this to `false` unless the workload actually calls the K8s API.

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

Known secrets (referenced in deployments): `gatus-secrets`, `transmission-auth`, `transmission-wireguard`, `immich-db-secret`, `pve-exporter-secret`, `bin-scraper-mqtt`, `bin-scraper-gh-token`, `bin-scraper-session`, `grafana-admin-secret`, `grafana-slack-webhook`, `flux-slack-webhook`, `authentik-secrets`, `jellyfin-api-key`.

A few secrets are committed as SOPS-encrypted `*.enc.yaml` instead, since Flux needs them present at reconcile time rather than pre-created imperatively: `ghcr-pull` (`apps/ghcr-pull-secret.enc.yaml`, see [ghcr-auth.md](ghcr-auth.md)) and `bin-scraper-address` (`apps/bin-scraper/address-secret.enc.yaml`, supplies `SCRAPER_POSTCODE`/`REPORTER_POSTCODE`/`REPORTER_ADDRESS_MATCH` so the scraper's postcode and address-match string aren't hardcoded in a tracked file).

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
| Awtrix | 192.168.0.30 |
| Claws host | 192.168.0.73 |

### Domains

| Domain | Resolves to | Use |
|--------|-------------|-----|
| `*.home.bstjohn.net` | 192.168.0.251 | LAN access; Tailscale access via public DNS + subnet router (no MagicDNS override) |
| `home.bstjohn.net` | 192.168.0.251 | Homepage dashboard (apex) |

### CI Configuration

CI is defined in `.github/workflows/ci.yml` and covers the entire monorepo (both `clusters/` and `apps/`). See [infrastructure-overview.md](infrastructure-overview.md) for full CI job details.

A separate workflow (`.github/workflows/update-bin-scraper.yml`) handles automated image updates for the bin-scraper service. It is triggered via `workflow_dispatch` (the bin-scraper repo's Release workflow dispatches it with `gh workflow run`, authorized by the org-level `FLEET_INFRA_VERSION_BUMP` PAT — see [infrastructure-overview.md](infrastructure-overview.md)), validates the tag format (`YYYYMMDD-N-HASH`), updates `apps/bin-scraper/deployment.yaml` in place, and opens a PR on an `automation/bump-bin-scraper-<tag>` branch labelled `dependencies,auto-bump`. This is the only GitOps automation in the repo that bypasses the manual PR review requirement: the `auto-bump` label marks the PR for Claws' auto-merger, which merges it once CI passes, instead of native GitHub auto-merge.

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
| Vaultwarden | vaultwarden.home.bstjohn.net | Deployed (no ForwardAuth, local-path, Recreate) |
| Bin Scraper | bin-scraper.home.bstjohn.net | Deployed |
| Transmission | transmission.home.bstjohn.net | Deployed (gated, paused at 0 replicas) |
| Sonarr | sonarr.home.bstjohn.net | Deployed |
| Radarr | radarr.home.bstjohn.net | Deployed |
| Prowlarr | prowlarr.home.bstjohn.net | Deployed |
| Bazarr | bazarr.home.bstjohn.net | Deployed |
| Overseerr | overseerr.home.bstjohn.net | Deployed |
| Jellyfin | jellyfin.home.bstjohn.net | Deployed |
| Jellyseerr | jellyseerr.home.bstjohn.net | Deployed |
| Seerr | seerr.home.bstjohn.net | Deployed (preview) |
| Home Assistant | home-assistant.home.bstjohn.net | External proxy |
| Plex | plex.home.bstjohn.net | Deployed (`k3s`, soft NFS media mount, gated via truenas-gate) |
| Wake NAS | wake.home.bstjohn.net | Deployed (truenas-gate wake page, always reachable) |
| Authentik | auth.home.bstjohn.net | Multi-deployment (SSO provider) |
| Headlamp | dashboard.home.bstjohn.net | Helm release |
| Forgejo | git.home.bstjohn.net | Deployed (15.0.5, push-mirrors to GitHub, Actions enabled, in-cluster runner; backups: [forgejo-backups.md](forgejo-backups.md)) |
| Datasette | datasette.home.bstjohn.net | Deployed |
| Chat (Open WebUI) | chat.home.bstjohn.net | Deployed |
| Arpwatch | — | Deployed (no ingress, hostNetwork) |
| Containerd GC (main node) | — | CronJob `containerd-gc` (daily 04:00, 300s deadline — completes in ~3s) |
| Containerd GC (k3s-nas) | — | CronJob `containerd-gc-storage` (daily 04:30, 1800s deadline, backoffLimit: 1 — HDD-backed node may have image backlog; resolves `crictl` via explicit host PATH — NixOS) |
| Config Backup (servarr) | — | CronJob `config-backup` on `k3s-nas` (nightly 02:00 Europe/London, SQLite-consistent backup of the four servarr config PVCs; see [config-backups.md](config-backups.md)) |
| Config Backup (players) | — | CronJob `config-backup-players` on `k3s` (nightly 01:00 Europe/London, same script, covers `plex-config`, `jellyfin-config`, `jellyseerr-config`, `seerr-config`) |
| Forgejo backup (local) | — | CronJob `forgejo-backup` (daily 02:30, `forgejo dump` → `forgejo-backups` local-path PVC, 14 retained) |
| Forgejo backup (offsite) | — | CronJob `forgejo-backup-offsite` (daily 03:00, copies new dumps to NFS `/media/backups/forgejo`, 14 retained) |
| Ollama | — | Deployed (GPU node, in-cluster only — accessed by open-webui via Service DNS) |
| Whisper | — | Deployed (GPU node, in-cluster only — audio transcription API, port 9000) |
| Awtrix | awtrix.home.bstjohn.net | External proxy |
| Claws | claws.home.bstjohn.net | External proxy |
| Claws (staging) | claws-staging.home.bstjohn.net | Deployed (containerized staging, 1 Gi PVC) |
| Proxmox | proxmox.home.bstjohn.net | External proxy (IngressRoute) |
| UniFi | unifi.home.bstjohn.net | External proxy (IngressRoute) |

*(gated) = routed through truenas-gate for availability handling*
