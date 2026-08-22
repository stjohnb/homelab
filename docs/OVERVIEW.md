# fleet-infra Overview

Complete GitOps configuration for a three-node k3s homelab cluster, managed by Flux CD. This monorepo contains both infrastructure platform components (`clusters/`) and application manifests (`apps/`). All changes are merged to `main` via Pull Request; Flux automatically reconciles the cluster within minutes.

## Repository Structure

```
fleet-infra/
├── clusters/my-cluster/               # Flux CD cluster configuration
│   ├── flux-system/                   #   Flux bootstrap (controllers, GitRepository, root Kustomization)
│   │   ├── gotk-components.yaml       #     Flux controllers (v2.7.5)
│   │   ├── gotk-sync.yaml            #     GitRepository + root Kustomization
│   │   └── notifications.yaml        #     Slack alerting (see docs/notifications.md)
│   ├── infrastructure/                #   Layer 1: cert-manager, godaddy-webhook, traefik (HelmRepository sources also: headlamp, nvidia-device-plugin, prometheus-community)
│   ├── config/                        #   Layer 2: certificates, RBAC (depends on infrastructure)
│   ├── kustomization.yaml             #   Root resource list (architectural safeguard)
│   ├── infrastructure-kustomization.yaml
│   ├── config-kustomization.yaml
│   ├── migrations-kustomization.yaml  #   Flux Kustomization → ./migrations (depends on infrastructure)
│   └── apps-kustomization.yaml        #   Flux Kustomization → ./apps (depends on config + migrations)
│
├── apps/                              # Application manifests (deployed to default namespace)
│   ├── kustomization.yaml             #   Lists all service directories
│   ├── priority-classes.yaml
│   ├── wildcard-home-cert.yaml        #   Shared TLS cert (*.home.bstjohn.net)
│   ├── ghcr-pull-secret.enc.yaml      #   SOPS-encrypted ghcr-pull dockerconfigjson Secret (shared by all default-ns apps)
│   ├── homepage/                      #   Dashboard
│   ├── gatus/                         #   Uptime monitoring
│   ├── monitoring/                    #   Prometheus + Grafana (Helm)
│   ├── immich/                        #   Photo management
│   ├── servarr/                       #   Media automation stack
│   ├── truenas-gate/                  #   Availability proxy for NAS-dependent services
│   ├── authentik/                     #   SSO provider (ForwardAuth)
│   ├── headlamp/                      #   Kubernetes web UI (Helm)
│   ├── ollama/                        #   LLM inference (GPU node)
│   ├── whisper/                       #   Audio transcription (GPU node)
│   └── ... (30+ services)
│
├── migrations/                        # Secret generation Jobs (separate Kustomization)
│
├── .claude/
│   └── agents/                        #   Subagent definitions for Claws (issue-refiner, issue-implementer, pr-reviewer)
├── .github/workflows/ci.yml          # CI pipeline
├── Taskfile.yaml                      # Local validation + cluster operations
├── renovate.json                      # Automated dependency updates
├── README.public.md                    # Hand-maintained README published as the public snapshot's README.md
└── .yamllint                          # YAML linting rules
```

## Architecture

### Flux Reconciliation Layers

Flux reconciles three layers in dependency order from a single Git source (`St-John-Software/fleet-infra`, branch `main`, 1-minute polling):

```
Layer 1: infrastructure  (10m interval, retryInterval: 1m, healthChecks: 3 HelmReleases, timeout: 5m)
    └── cert-manager, godaddy-webhook, traefik

Layer 2: config          (10m interval, retryInterval: 1m, dependsOn: infrastructure, wait: true)
    └── certificates (ClusterIssuers, wildcard cert), RBAC

Layer 2: migrations      (1m interval, dependsOn: infrastructure, prune: true, path: ./migrations)
    └── Jobs: auto-generate secrets, track completion in migration-state ConfigMap
    └── (runs in parallel with config — depends on infrastructure, not config)

Layer 3: apps            (1m interval, dependsOn: config + migrations, prune: true, path: ./apps)
    └── All application services → default namespace
```

The `config` layer depends on `infrastructure` (cert-manager must be running before ClusterIssuers are created). The `migrations` layer also depends on `infrastructure` and runs in parallel with `config` — it generates secrets that apps need, but does not require certificates or RBAC. The `apps` layer depends on both `config` and `migrations`, ensuring certificates exist and secrets are populated before application pods start.

**Root Kustomization safeguard**: The explicit `clusters/my-cluster/kustomization.yaml` prevents Flux from auto-discovering subdirectories and bypassing the `dependsOn` chain. Without it, the root Kustomization would apply Certificate resources before cert-manager CRDs are available.

**Retry interval**: The `retryInterval: 1m` on infrastructure and config layers handles a race condition where simultaneous layer reconciliation can pass `dependsOn` checks based on stale Ready status.

**Health checks**: The `infrastructure` layer gates on its three HelmReleases rather than `wait: true`, so a transient HelmRepository chart-index fetch failure doesn't stall the whole layer — see [Why infrastructure uses healthChecks instead of wait](infrastructure-overview.md#why-infrastructure-uses-healthchecks-instead-of-wait).

### Namespace Layout

| Namespace | Contents |
|-----------|----------|
| `flux-system` | Flux controllers, GitRepository, Kustomizations, HelmRepositories, HelmReleases |
| `cert-manager` | cert-manager pods, GoDaddy webhook |
| `traefik` | Traefik ingress controller |
| `default` | All application workloads, wildcard TLS certificate, RBAC, `ghcr-pull` dockerconfigjson Secret |
| `kube-system` | nvidia-device-plugin DaemonSet (see [infrastructure-overview.md](infrastructure-overview.md#namespace-layout) for the HelmRelease namespace quirk) |

### Health Checks

Flux verifies critical deployments reach Ready status within 5 minutes after applying app manifests. Failures trigger Slack notifications.

Monitored resources: Deployments (`gatus`, `homepage`). The `kube-prometheus-stack` HelmRelease is intentionally excluded — its reconciliation on a single-node cluster routinely exceeds the 5-minute timeout while in 'InProgress' state, producing noisy false-positive Slack alerts. Actual HelmRelease failures are still reported via the `slack-errors` alert, which watches it directly. Intentionally excluded: Immich (depends on NFS from the NAS, which is not always on — would produce false-positive alerts every minute), the standalone `pve-exporter` (a peripheral metric collector with external dependencies).

CronJob health is monitored via Grafana alert rules (not Flux health checks): Immich DB backup, Forgejo backup (local and offsite), both config backups (servarr on `k3s-nas`, Plex/Jellyfin on `k3s`), and containerd-gc are tracked for failures and missed schedules. See [docs/monitoring.md](monitoring.md). For the Forgejo two-stage backup design and restore runbook, see [docs/forgejo-backups.md](forgejo-backups.md).

## Key Patterns

### GitOps Workflow

```
Feature Branch → Pull Request → CI Validation → Merge → Flux Reconciliation → Cluster
```

- **Branch protection**: Direct pushes to `main` are blocked
- **No `kubectl apply`**: Flux owns cluster state (exception: secrets, emergency debugging)
- All changes require PR review

### TLS: Shared Wildcard Certificate

A single `Certificate` resource (`apps/wildcard-home-cert.yaml`) covers `*.home.bstjohn.net` and `home.bstjohn.net`. All ingresses reference `secretName: wildcard-home-tls`.

**Never** add `cert-manager.io/cluster-issuer` annotations to ingresses or create per-service Certificate resources — this creates DNS TXT records that break wildcard resolution.

### Ingress Convention

```yaml
spec:
  ingressClassName: traefik-traefik    # NOT "traefik"
  tls:
    - hosts: [service.home.bstjohn.net]
      secretName: wildcard-home-tls    # Shared cert, never per-service
```

All services use `*.home.bstjohn.net` (LAN) hostnames. Tailscale resolves the same domain via public DNS and reaches it through a subnet router advertising `192.168.0.0/24` — see [Remote access over Tailscale](infrastructure-overview.md#remote-access-over-tailscale).

### SSO: Authentik ForwardAuth

Authentik (`apps/authentik/`) provides centralized SSO using two integration modes. **ForwardAuth**: a chain of three Traefik `Middleware` CRDs — header stripping, ForwardAuth, and a combining chain (`authentik-auth`) — protects 8 services (Sonarr, Radarr, Prowlarr, Bazarr, Transmission, Grafana, Prometheus, Datasette). **Native OIDC**: 11 services (Mealie, Open WebUI, Jellyfin, Jellyseerr, Headlamp, Proxmox, Bin Scraper, Claws, Forgejo, Seerr, Home Assistant) integrate via Authentik's OAuth2/OIDC provider — no ingress annotation needed. All providers, applications, users, groups, and policy bindings are configured declaratively via Authentik blueprints (`configmap-blueprints.yaml`): 8 ForwardAuth providers (home domain only) + 11 OIDC providers, 8 ForwardAuth applications + 11 OIDC applications, 4 groups (`all-apps`, `media`, `home`, `infra`), 2 users, and 16 ForwardAuth policy bindings. The ForwardAuth address uses the FQDN (`authentik-server.default.svc.cluster.local`) because Traefik resolves it from the `traefik` namespace. Home Assistant's OIDC provider is wired (worker env + migration 0022) but not yet consumed HA-side — no ingress change until the `auth_oidc` component is vendored into `home-assistant-config`. Services with their own auth (Immich, Plex, Overseerr), the public homepage, and Gatus (kept outside ForwardAuth so monitoring remains accessible during an Authentik outage) are intentionally excluded. See [docs/authentik.md](authentik.md).

### Domain Access

| Domain | Resolves to | Use |
|--------|-------------|-----|
| `*.home.bstjohn.net` | 192.168.0.251 | LAN access; Tailscale access via public DNS + subnet router (no MagicDNS override) |

### Storage Strategy

| Class | When to use | Survives NAS offline | Examples |
|-------|-------------|--------------------------|----------|
| `local-path` | Infrastructure, config, databases | Yes | gatus, monitoring |
| NFS (`192.168.0.128`) | Large media/data | No (pod evicted after ~5min) | transmission downloads, sonarr/radarr media, immich photos |

NFS-*writing* services (Sonarr, Radarr, Bazarr, Transmission, Immich, plus the `immich-db-backup`, `config-backup` and `containerd-gc-storage` CronJobs) are pinned to the NAS worker node (`k3s-nas`) via `nodeSelector: node-role.kubernetes.io/storage: "true"` — see [docs/nas-k3s.md](nas-k3s.md). This pinning is a hard availability constraint, not a locality optimisation: the NAS box is deliberately powered off most of the time, they all mount NFS `hard`, and they cannot function without it regardless of network speed.

Plex and Jellyfin are the exception (#800). They only read the media share, so they run on `k3s` against `media-soft-pvc` — a second PV over the same export mounted `soft,timeo=50,retrans=2` — and stay up while the NAS sleeps, failing playback with `EIO` rather than hanging. Their library scanners are disabled to stop an empty-looking tree being read as deleted media. Jellyfin's are held disabled declaratively by a `config-reconciler` sidecar (#807), which also enforces the Authentik SSO plugin config and login button (#817); Plex's are still set by hand. See [docs/nas-app-tier-migration.md](nas-app-tier-migration.md).

GPU-dependent services (Ollama, Whisper) are pinned to the `ryzen` node via `nodeSelector: node-role.kubernetes.io/gpu: "true"` — see [docs/gpu-k3s.md](gpu-k3s.md).

### Priority Classes

Defined in `apps/priority-classes.yaml`. Used to protect critical services from eviction under memory pressure:

| Priority | Value | Services |
|----------|-------|----------|
| `critical-infrastructure` | 1000000 | gatus, authentik-server, authentik-postgresql, kube-prometheus-stack (Grafana + Prometheus) |
| `standard` | 500000 | homepage, immich, mealie, vaultwarden, truenas-gate, authentik-worker, ollama, whisper, forgejo, claws (staging) |
| `low-priority` | 100000 | servarr services, bin-scraper, arpwatch, datasette, jellyfin, jellyseerr, seerr, open-webui, plex, pve-exporter, forgejo-runner |

### Secrets

Never committed to Git. Created imperatively with `kubectl create secret`. See detailed docs for per-component secret references.

**GHCR pull auth** (`ghcr.io/st-john-software/*`) uses a static GitHub PAT stored as a SOPS-encrypted `dockerconfigjson` Secret at `apps/ghcr-pull-secret.enc.yaml`. Flux's `kustomize-controller` decrypts at reconcile time using `flux-system/sops-age`. New apps in `default` namespace only need `imagePullSecrets: [{name: ghcr-pull}]`. See [docs/ghcr-auth.md](ghcr-auth.md).

### Image Pinning

All container images pinned to specific version tags — never `:latest`. Renovate automates dependency update PRs for both Helm charts and container images.

## Configuration

### Network

| Purpose | Address |
|---------|---------|
| Main k3s node (Traefik LB, control-plane) | 192.168.0.251 |
| NAS/storage worker node (`k3s-nas`, NixOS bare-metal, formerly TrueNAS CORE — see [docs/nas-k3s.md](nas-k3s.md)) | 192.168.0.128 (static, pinned in NixOS config) |
| GPU worker node (NVIDIA host, Ollama + future TTS) | 192.168.0.69 |
| Tailscale IP | 100.78.7.18 |
| Proxmox host | 192.168.0.200 |

### CI Pipeline

Defined in `.github/workflows/ci.yml`. Runs on PRs targeting `main` and pushes to `main`. Self-hosted runner. A separate workflow (`.github/workflows/build-arpwatch.yml`) builds the custom arpwatch container image on pushes to `main` (path-filtered to `images/arpwatch/**`). Both workflows use per-branch concurrency groups with `cancel-in-progress: true`.

Three additional operational workflows run outside the PR cycle:
- **`notify-failures.yml`** — watches `build-arpwatch.yml`, `ci.yml`, and `cleanup-actions-storage.yml` completions on `main`; creates a `bug`-labelled GitHub issue when any fails (deduplicates to avoid duplicate issues), and auto-closes the issue when the build recovers.
- **`update-bin-scraper.yml`** — triggered via `workflow_dispatch` (`gh workflow run` from the bin-scraper repo's Release workflow, authorized by the org-level `FLEET_INFRA_VERSION_BUMP` PAT); validates tag format, updates `apps/bin-scraper/deployment.yaml`, and opens a PR (`automation/bump-bin-scraper-<tag>` branch, `auto-bump` label) for Claws' auto-merger to merge once CI passes. The only place in the repo where auto-merge is intentionally enabled — no native GitHub auto-merge, since with no required status checks on `main` it races GitHub's mergeability computation unreliably. See [infrastructure-overview.md](infrastructure-overview.md) for the PAT's required scopes.
- **`cleanup-actions-storage.yml`** — runs weekly (Monday 04:00 UTC) and on `workflow_dispatch`; deletes all Actions artifacts and caches. Safe to delete all because this repo deliberately produces zero artifacts (`DOCKER_BUILD_RECORD_UPLOAD: false` in `build-arpwatch.yml`, no `upload-artifact` anywhere). Prevents `.dockerbuild` build-record accumulation against the org-shared 2 GB GitHub Actions storage quota.

| Job | Purpose | Blocking |
|-----|---------|----------|
| `yaml-lint` | YAML syntax/formatting (yamllint) | Yes |
| `kustomize-validate` | All overlays compile | Yes |
| `kubeconform` | Schema validation (K8s + Flux CRDs) | Yes |
| `security-scan` | kubesec score check (fails on critical) | Yes |
| `image-scan` | Trivy CRITICAL CVEs on changed images (PR only) | Yes |
| `secret-detection` | Blocks hardcoded secrets (gitleaks, 150+ patterns) | Yes |
| `kustomization-completeness` | Verifies all service dirs listed in parent kustomization.yaml | Yes |
| `renovate-check` | Validates `renovate.json` syntax | Yes |
| `trivyignore-check` | Validates `.trivyignore` governance (expiry dates, format, upstream links) | Yes |
| `ingress-uniqueness` | Verifies no two Ingress/IngressRoute resources claim the same hostname | Yes |
| `gate-netpol` | Verifies truenas-gate-fronted services allow ingress from the gate | Yes |
| `image-pull-secrets` | Verifies every `imagePullSecrets` reference resolves to a declared dockerconfigjson Secret | Yes |
| `image-consistency` | Verifies no service directory pins the same image to two different tags | Yes |
| `kustomize-diff` | Posts rendered manifest diff (apps + clusters + migrations) as PR comment | No |
| `image-verify` | Verifies container images exist in their registries (crane, standalone) | No |

All CI tooling is repo-owned via `flake.nix`, entered per-job with `nix develop` — the self-hosted runners provide only `nix`, `git`, and `docker` as a baseline. See [infrastructure-overview.md](infrastructure-overview.md#toolchain-repo-owned-via-flakenix-pr-754).

Run locally: `task validate` (lint + kustomize + kubeconform + check-completeness + trivyignore-check + check-ingress-uniqueness + check-image-consistency + check-gate-netpol + check-image-pull-secrets). Run `task renovate-check` separately — it validates `renovate.json` syntax (via npx, optional) and checks that all dependency-bearing files are covered by Renovate `fileMatch` patterns.

### Task Runner

[`Taskfile.yaml`](../Taskfile.yaml) provides targets for local validation and cluster operations. Running `task` with no arguments runs the full validation suite.

| Task | Description |
|------|-------------|
| `task validate` | Full CI pipeline locally (lint → kustomize → kubeconform → check-completeness → trivyignore-check → check-ingress-uniqueness → check-image-consistency → check-gate-netpol) |
| `task lint` | YAML lint only (yamllint) |
| `task image-verify` | Verify changed container image references are pullable (crane) |
| `task trivyignore-check` | Validate `.trivyignore` format, expiry dates, and upstream links |
| `task reconcile` | Force immediate Flux reconciliation |
| `task status` | Show all Flux resources |
| `task suspend` / `task resume` | Pause/unpause reconciliation |
| `task diff` | Preview what Flux would apply |
| `task logs` | Tail Flux controller logs |

### Automated Dependency Updates

Configured via `renovate.json` (detects `HelmRelease` resources through the `flux` manager and container images through the `kubernetes` manager, plus six regex `customManagers` for CI tool versions, Flux CRD schema URLs, and the Flux GitHub Action version) — but **no Renovate app is actually installed against this repo**: zero Renovate-authored PRs have ever existed here (confirmed via `gh api .../issues?creator=renovate[bot]` during #701). Don't assume Renovate will catch a stale image tag or chart version until this is fixed; see [infrastructure-overview.md](infrastructure-overview.md#automated-dependency-updates) for the full investigation. All PRs (once it's actually running) require manual review.

## Subsystem Documentation

- [Infrastructure Components](infrastructure-overview.md) — Traefik, cert-manager, GoDaddy webhook, Flux bootstrap, RBAC, CI pipeline details
- [Applications Overview](apps-overview.md) — All 30+ services, service types, Headlamp, migrations, adding new services
- [Monitoring Stack](monitoring.md) — Prometheus, Grafana, PVE exporter, dashboards
- [Servarr Media Stack](servarr.md) — Transmission (WireGuard VPN), Sonarr, Radarr, Prowlarr, Bazarr, Overseerr
- [TrueNAS Gate](truenas-gate.md) — Availability proxy for NAS-dependent services
- [NAS Storage Node](nas-k3s.md) — NixOS bare-metal NAS host as k3s worker (migrated from TrueNAS CORE 2026-07-27), NFS-dependent service scheduling, offline behaviour
- [GPU Worker Node](gpu-k3s.md) — Ubuntu host with NVIDIA GPU joined as k3s worker, NVIDIA device plugin, RuntimeClass, Ollama deployment
- [Immich](immich.md) — Photo management with ML, PostgreSQL, Valkey, database backups
- [Config Backups](config-backups.md) — nightly SQLite-consistent backups of the six servarr/Jellyfin/Plex config PVCs across two CronJobs, plus the July 2026 zvol-recovery record and restore runbook
- [NAS App Tier Migration](nas-app-tier-migration.md) — the #800 cutover runbook that moved Plex and Jellyfin to `k3s` on a soft NFS mount
- [Forgejo](forgejo.md) — Self-hosted Git forge, SQLite/PVC layout, upgrade runbook, Actions OIDC and ephemeral runners
- [Forgejo Backups](forgejo-backups.md) — Two-stage backup design (local + offsite), restore runbook
- [Authentik SSO](authentik.md) — ForwardAuth middleware, protected services, Grafana proxy auth
- [Flux Notifications](notifications.md) — Slack alerting for reconciliation failures, Grafana annotations for successful deployments
- [ghcr-auth.md](ghcr-auth.md) — GHCR auth via static PAT + SOPS: bootstrap, PAT rotation, and per-namespace pattern
- [Forgejo Mirroring](forgejo-mirroring.md) — Push mirrors from in-cluster Forgejo to GitHub for DR, mirror direction rules, PAT rotation
- [Forgejo Actions](forgejo-actions.md) — In-cluster forgejo-runner with a Docker-in-Docker sidecar, offline registration, runner labels
- [Claws Automation](claws-automation.md) — How the Claws agent manages issues, PRs, and labels in this repo
- [Standing Requirements](requirements.md) — Cross-cutting owner constraints that don't belong to a single subsystem doc

### Public snapshot

This repo is mirrored to a public GitHub repository. `README.public.md` replaces `README.md` there and must be updated by hand whenever `README.md` changes.
