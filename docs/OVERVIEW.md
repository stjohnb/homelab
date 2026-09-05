# fleet-infra Overview

| Doc | Read this when | Depth |
|-----|-----------------|-------|
| [OVERVIEW.md](OVERVIEW.md) | Starting any planning or implementation work in this repo | **Entry point** |
| [infrastructure-overview.md](infrastructure-overview.md) | Touching Traefik, cert-manager, Route53 DNS-01, Flux bootstrap, RBAC, or the CI pipeline | Reference |
| [apps-overview.md](apps-overview.md) | Adding a new service, or need the full list/shape of the 30+ existing ones | Reference |
| [monitoring.md](monitoring.md) | Touching Prometheus, Grafana, alert rules, or the PVE exporter | Reference |
| [servarr.md](servarr.md) | Working on Transmission, Sonarr, Radarr, Prowlarr, Bazarr, or Overseerr | Reference |
| [truenas-gate.md](truenas-gate.md) | Working on the availability proxy that fronts NAS-dependent services | Reference |
| [nas-k3s.md](nas-k3s.md) | Working on the NAS worker node, NFS mounts, or offline-NAS behaviour | Reference |
| [gpu-k3s.md](gpu-k3s.md) | Working on the GPU worker node, NVIDIA device plugin, Ollama, or Whisper | Reference |
| [postgres.md](postgres.md) | Adding a database or touching the shared `apps/postgres` instance | Reference |
| [immich.md](immich.md) | Working on Immich (photo management), its DB, or its backups | Reference |
| [config-backups.md](config-backups.md) | Restoring or changing the servarr/Jellyfin/Plex config PVC backups | Deep dive |
| [nas-app-tier-migration.md](nas-app-tier-migration.md) | Understanding why Plex/Jellyfin run on soft NFS on `k3s`, or repeating a similar migration | Deep dive |
| [forgejo.md](forgejo.md) | Working on the self-hosted Git forge, its storage, or upgrades | Reference |
| [forgejo-backups.md](forgejo-backups.md) | Restoring or changing Forgejo's local/offsite backups | Deep dive |
| [forgejo-mirroring.md](forgejo-mirroring.md) | Working on push mirrors from Forgejo to GitHub | Reference |
| [forgejo-actions.md](forgejo-actions.md) | Working on the in-cluster forgejo-runner or its Docker-in-Docker sidecar | Reference |
| [authentik.md](authentik.md) | Adding SSO to a service, or touching ForwardAuth/OIDC providers | Reference |
| [notifications.md](notifications.md) | Working on Flux Slack alerting or Grafana deployment annotations | Reference |
| [ghcr-auth.md](ghcr-auth.md) | Debugging image pull auth, or wiring pull secrets for a new service | Reference |
| [registry.md](registry.md) | Working on the self-hosted zot registry | Reference |
| [claws-automation.md](claws-automation.md) | Understanding how the Claws agent manages issues/PRs/labels in this repo | Reference |
| [requirements.md](requirements.md) | Proposing something cross-cutting (autoscaling, new auth pattern, CI policy gate) — check it isn't already rejected | Reference |
| [agent-notes.md](agent-notes.md) | Debugging manually on the shared host and need verified host/CI gotchas | Reference |

## Purpose

Complete GitOps configuration for a three-node k3s homelab cluster, managed by Flux CD. This monorepo contains both infrastructure platform components (`clusters/`) and application manifests (`apps/`). All changes are merged to `main` via Pull Request; Flux automatically reconciles the cluster within minutes.

## Repository Structure

```
fleet-infra/
├── clusters/my-cluster/               # Flux CD cluster configuration
│   ├── flux-system/                   #   Flux bootstrap (controllers, GitRepository, root Kustomization)
│   │   ├── gotk-components.yaml       #     Flux controllers (v2.7.5)
│   │   ├── gotk-sync.yaml            #     GitRepository + root Kustomization
│   │   └── notifications.yaml        #     Slack alerting (see docs/notifications.md)
│   ├── infrastructure/                #   Layer 1: cert-manager, traefik (HelmRepository sources also: headlamp, nvidia-device-plugin, prometheus-community)
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
├── .agents/                            #   Role documents injected as system prompts into Claws' headless runs (issue-refiner, issue-implementer, pr-reviewer)
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
Layer 1: infrastructure  (10m interval, retryInterval: 1m, healthChecks: 2 HelmReleases, timeout: 5m)
    └── cert-manager, traefik

Layer 2: config          (10m interval, retryInterval: 1m, dependsOn: infrastructure, wait: true)
    └── certificates (ClusterIssuers, wildcard cert), RBAC

Layer 2: migrations      (1m interval, dependsOn: infrastructure, prune: true, path: ./migrations)
    └── Jobs: auto-generate secrets, track completion in migration-state ConfigMap
    └── (runs in parallel with config — depends on infrastructure, not config)

Layer 3: apps            (1m interval, dependsOn: config + migrations, prune: true, path: ./apps)
    └── All application services → default namespace
```

The `config` layer depends on `infrastructure` (cert-manager must be running before ClusterIssuers are created). The `migrations` layer also depends on `infrastructure` and runs in parallel with `config` — it generates secrets that apps need, but does not require certificates or RBAC. The `apps` layer depends on both `config` and `migrations`, ensuring certificates exist and secrets are populated before application pods start. Because `migrations/job.yaml` is annotated `kustomize.toolkit.fluxcd.io/force: enabled` and its scripts come from a hash-suffixed `configMapGenerator`, a merged migration runs on the next reconcile with no human step — see [Secret Migration Jobs](apps-overview.md#secret-migration-jobs).

**Root Kustomization safeguard**: The explicit `clusters/my-cluster/kustomization.yaml` prevents Flux from auto-discovering subdirectories and bypassing the `dependsOn` chain. Without it, the root Kustomization would apply Certificate resources before cert-manager CRDs are available.

**Retry interval**: The `retryInterval: 1m` on infrastructure and config layers handles a race condition where simultaneous layer reconciliation can pass `dependsOn` checks based on stale Ready status.

**Health checks**: The `infrastructure` layer gates on its three HelmReleases rather than `wait: true`, so a transient HelmRepository chart-index fetch failure doesn't stall the whole layer — see [Why infrastructure uses healthChecks instead of wait](infrastructure-overview.md#why-infrastructure-uses-healthchecks-instead-of-wait).

### Namespace Layout

| Namespace | Contents |
|-----------|----------|
| `flux-system` | Flux controllers, GitRepository, Kustomizations, HelmRepositories, HelmReleases |
| `cert-manager` | cert-manager pods |
| `traefik` | Traefik ingress controller |
| `default` | All application workloads, wildcard TLS certificate, RBAC, `ghcr-pull` dockerconfigjson Secret |
| `kube-system` | nvidia-device-plugin DaemonSet (see [infrastructure-overview.md](infrastructure-overview.md#namespace-layout) for the HelmRelease namespace quirk) |

### Health Checks

Flux verifies critical deployments reach Ready status within 5 minutes after applying app manifests. Failures trigger Slack notifications.

Monitored resources: Deployments (`gatus`, `homepage`, `homepage-limited`, `homepage-router`). The `kube-prometheus-stack` HelmRelease is intentionally excluded, and as of #890 sets `disableWait: true` on install/upgrade/rollback: Helm's `--wait` gated release success on the `prometheus-node-exporter` DaemonSet reaching its readiness threshold, which the GPU (`ryzen`) and NAS (`k3s-nas`) workers being powered off for most of the day made impossible to satisfy whenever both were down — the root cause of a months-long recurring `[k3s] Flux HelmRelease NotReady` alert series. With waiting disabled, Flux reports the release Ready as soon as manifests apply and no longer auto-rolls-back a functionally broken upgrade; health detection instead comes from Gatus probes of the Grafana and Prometheus endpoints in `apps/gatus/config.yaml`. See [monitoring.md](monitoring.md#kube-prometheus-stack-helmrelease). Intentionally excluded: Immich (depends on NFS from the NAS, which is not always on — would produce false-positive alerts every minute), the standalone `pve-exporter` (a peripheral metric collector with external dependencies).

The `migrations` layer has its own failure path, separate from the `apps`/`infrastructure`/`config` health checks above: a Kustomization build/apply error on `./migrations` reaches Slack via the `slack-errors` Flux Alert (#885), while a failing *migration script* (the Kustomization still applies fine) is caught instead by the `Migration Runner Job Failed` Grafana rule watching `kube_job_status_failed{job_name="migration-runner"}`, wrapped in `max_over_time(...[20m])` to bridge the gap left by `ttlSecondsAfterFinished` deleting the Job between reconciles.

CronJob health is monitored via Grafana alert rules (not Flux health checks): Immich DB backup, Forgejo backup (local and offsite), both config backups (servarr on `k3s-nas`, Plex/Jellyfin on `k3s`), containerd-gc, and the `migration-runner` Job are tracked for failures and missed schedules. See [docs/monitoring.md](monitoring.md). For the Forgejo two-stage backup design and restore runbook, see [docs/forgejo-backups.md](forgejo-backups.md).

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

All services use `*.home.bstjohn.net` (LAN) hostnames, and every hostname has a sibling `*.ext.bstjohn.net` on the same resource. ForwardAuth ext hosts use their own `<svc>-ext` Ingress and the `authentik-auth-ext` chain (#1111). Tailscale split DNS sends `home.bstjohn.net` to the in-cluster `tailnet-dns` resolver at `100.78.7.18` (`apps/tailnet-dns/`), which answers `100.78.7.18` for the apex and every subdomain, so `.home` reaches Traefik with no subnet router; the openclaw subnet router remains the fallback for encrypted-DNS clients. `*.ext` resolves to the `k3s` node's own tailnet address and needs no subnet router either — see [Remote access over Tailscale](infrastructure-overview.md#remote-access-over-tailscale).

### SSO: Authentik ForwardAuth

Authentik (`apps/authentik/`) provides centralized SSO using two integration modes. **ForwardAuth**: five Traefik `Middleware` CRDs forming two chains — shared header stripping plus a ForwardAuth and combining chain per outpost (`authentik-auth` for `.home.`, `authentik-auth-ext` for `.ext.`) — protect 12 services (Sonarr, Radarr, Prowlarr, Bazarr, Transmission, Grafana, Prometheus, Homepage, Awtrix Kitchen, Awtrix Office, Navidrome, Music Assistant). **Native OIDC**: 12 services (Mealie, Jellyfin, Jellyseerr, Headlamp, Proxmox, Bin Scraper, Claws, Forgejo, Seerr, Home Assistant, Container Registry, Garden) integrate via Authentik's OAuth2/OIDC provider — no ingress annotation needed. All providers, applications, users, groups, and policy bindings are configured declaratively via Authentik blueprints (`configmap-blueprints.yaml`): 24 ForwardAuth providers (12 services × home + ext) + 12 OIDC providers, 24 ForwardAuth applications + 12 OIDC applications (+12 provider-less ext bookmarks), 4 groups (`all-apps`, `media`, `home`, `infra`), 2 users, and 72 policy bindings. Navidrome is the one ForwardAuth service with a split router — the Subsonic API and public shares bypass ForwardAuth so mobile clients keep working; see [Navidrome: Split Router for Subsonic Clients](authentik.md#navidrome-split-router-for-subsonic-clients-962). The ForwardAuth address uses the FQDN (`authentik-server.default.svc.cluster.local`) because Traefik resolves it from the `traefik` namespace. Home Assistant's OIDC provider is wired (worker env + migration 0022) but not yet consumed HA-side — no ingress change until the `auth_oidc` component is vendored into `home-assistant-config`. Services with their own auth (Immich, Plex, Overseerr) and Gatus (kept outside ForwardAuth so monitoring remains accessible during an Authentik outage) are intentionally excluded. See [docs/authentik.md](authentik.md).

### Domain Access

| Domain | Resolves to | Use |
|--------|-------------|-----|
| `*.home.bstjohn.net` | 192.168.0.251 (LAN DNS) / 100.78.7.18 (tailnet split DNS) | LAN access; Tailscale split DNS routes to the in-cluster resolver, subnet router as fallback |
| `*.ext.bstjohn.net` | 100.78.7.18 | Tailnet access straight to the `k3s` node's Traefik, no subnet router needed |

### Storage Strategy

| Class | When to use | Survives NAS offline | Examples |
|-------|-------------|--------------------------|----------|
| `local-path` | Infrastructure, config, databases | Yes | gatus, monitoring |
| NFS (`192.168.0.128`) | Large media/data | No (pod evicted after ~5min) | transmission downloads, sonarr/radarr media, immich photos |

NFS-*writing* services (Sonarr, Radarr, Bazarr, Transmission, Immich, plus the `immich-db-backup`, `config-backup` and `containerd-gc-storage` CronJobs) are pinned to the NAS worker node (`k3s-nas`) via `nodeSelector: node-role.kubernetes.io/storage: "true"` — see [docs/nas-k3s.md](nas-k3s.md). This pinning is a hard availability constraint, not a locality optimisation: the NAS box is deliberately powered off most of the time, they all mount NFS `hard`, and they cannot function without it regardless of network speed.

Plex and Jellyfin are the exception (#800). They only read the media share, so they run on `k3s` against `media-soft-pvc` — a second PV over the same export mounted `soft,timeo=50,retrans=2` — and stay up while the NAS sleeps, failing playback with `EIO` rather than hanging. Their library scanners are disabled to stop an empty-looking tree being read as deleted media. Jellyfin's are held disabled declaratively by a `config-reconciler` sidecar (#807), which also owns the scan cadence, gated on the NAS being up and the media mount populated (#1075), and enforces the Authentik SSO plugin config and login button (#817); Plex's are still set by hand. See [docs/nas-app-tier-migration.md](nas-app-tier-migration.md).

GPU-dependent services (Ollama, Whisper) are pinned to the `ryzen` node via `nodeSelector: node-role.kubernetes.io/gpu: "true"` — see [docs/gpu-k3s.md](gpu-k3s.md).

### Priority Classes

Defined in `apps/priority-classes.yaml`. Used to protect critical services from eviction under memory pressure:

| Priority | Value | Services |
|----------|-------|----------|
| `critical-infrastructure` | 1000000 | gatus, authentik-server, postgres (shared instance, see [postgres.md](postgres.md)), kube-prometheus-stack (Grafana + Prometheus) |
| `standard` | 500000 | homepage, immich, mealie, truenas-gate, authentik-worker, ollama, whisper, forgejo, claws (staging), tailnet-dns |
| `low-priority` | 100000 | servarr services, bin-scraper, arpwatch, jellyfin, navidrome, jellyseerr, seerr, plex, pve-exporter, forgejo-runner |

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

A second image-build workflow, `build-forgejo-runner-nix.yml`, builds the Forgejo Actions job image from `images/forgejo-runner-nix/**` with the same concurrency and `DOCKER_BUILD_RECORD_UPLOAD: false` pattern.

Failures of any of these workflows on `main` are not tracked by a workflow in this repo: Claws' central `main-build-monitor` job (St-John-Software/claws#2778) watches every default-branch `push`/`schedule` run, retries once when the failure looks transient, files or bumps a `Build failure: <workflow>` issue here otherwise, and closes it with a comment when a later run of the same workflow succeeds.

Several additional operational workflows run outside the PR cycle:
- **`update-bin-scraper.yml`** — triggered via `workflow_dispatch` (`gh workflow run` from the bin-scraper repo's Release workflow, authorized by the org-level `FLEET_INFRA_VERSION_BUMP` PAT); validates tag format, updates `apps/bin-scraper/deployment.yaml`, and opens a PR (`automation/bump-bin-scraper-<tag>` branch, `auto-bump` label) for Claws' auto-merger to merge once CI passes. The only place in the repo where auto-merge is intentionally enabled — no native GitHub auto-merge, since with no required status checks on `main` it races GitHub's mergeability computation unreliably. See [infrastructure-overview.md](infrastructure-overview.md) for the PAT's required scopes.
- **`update-garden.yml` / `update-claws-staging.yml`** — the same `workflow_dispatch` image-bump handshake for Garden and for `claws-staging`. `update-claws-staging.yml` differs in two ways: it validates the `vYYYY-MM-DD.N` tag format and rewrites the image reference across `apps/claws/*.yaml` (rather than a hard-coded filename, which claws#2752's StatefulSet rename would break), and it uses a single fixed branch `automation/bump-claws-staging` instead of a per-tag branch, because claws cuts a release on every push to `main` — the one open PR is force-updated to the newest tag rather than accumulating conflicting PRs.
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
| `migration-exec-secrets` | Verifies no `migrations/*.sh` script passes secret material (`--secret`/`--token`/`--password`/`--client-secret`/`--admin-token`) as a `kubectl exec` argument — the exec API encodes argv as a `command=` query parameter, captured verbatim by Kubernetes audit logging at any level (#902) | Yes |
| `migration-secret-rbac` | Verifies every Secret a `migrations/*.sh` script reads with `kubectl get secret` has a matching `resourceNames` + `get` grant in `migrations/rbac.yaml` — RBAC denial returns Forbidden, not NotFound, so a missing grant makes the script's idempotency guard silently inoperative (#923) | Yes |
| `kustomize-diff` | Posts rendered manifest diff (apps + clusters + migrations) as PR comment | No |
| `image-verify` | Verifies container images exist in their registries (crane, standalone) | No |

All CI tooling is repo-owned via `flake.nix`, entered per-job with `nix develop` — the self-hosted runners provide only `nix`, `git`, and `docker` as a baseline. See [infrastructure-overview.md](infrastructure-overview.md#toolchain-repo-owned-via-flakenix-pr-754).

Run locally: `task validate` (lint + kustomize + kubeconform + check-completeness + trivyignore-check + check-ingress-uniqueness + check-image-consistency + check-gate-netpol + check-image-pull-secrets + check-migration-exec-secrets + check-migration-secret-rbac + check-kubesec). Run `task renovate-check` separately — it validates `renovate.json` syntax (via npx, optional) and checks that all dependency-bearing files are covered by Renovate `fileMatch` patterns.

### Task Runner

[`Taskfile.yaml`](../Taskfile.yaml) provides targets for local validation and cluster operations. Running `task` with no arguments runs the full validation suite.

| Task | Description |
|------|-------------|
| `task validate` | Full CI pipeline locally (lint → kustomize → kubeconform → check-completeness → trivyignore-check → check-ingress-uniqueness → check-image-consistency → check-gate-netpol → check-image-pull-secrets → check-migration-exec-secrets → check-migration-secret-rbac → check-kubesec) |
| `task lint` | YAML lint only (yamllint) |
| `task image-verify` | Verify changed container image references are pullable (crane) |
| `task trivyignore-check` | Validate `.trivyignore` format, expiry dates, and upstream links |
| `task reconcile` | Force immediate Flux reconciliation |
| `task status` | Show all Flux resources |
| `task suspend` / `task resume` | Pause/unpause reconciliation |
| `task diff` | Preview what Flux would apply |
| `task logs` | Tail Flux controller logs |

### Automated Dependency Updates

Configured via `renovate.json` (detects `HelmRelease` resources through the `flux` manager and container images through the `kubernetes` manager, plus six regex `customManagers` for CI tool versions, Flux CRD schema URLs, and the Flux GitHub Action version) and runs self-hosted via `.github/workflows/renovate.yml` on `[self-hosted, linux]`, weekly plus `workflow_dispatch` (with `dry_run` and `log_level` inputs), authenticated with a dedicated repo-level `RENOVATE_TOKEN` PAT secret (separate from `FLEET_INFRA_VERSION_BUMP`; needs Issues, Workflows, Commit statuses and Dependabot-alerts permissions). See [infrastructure-overview.md](infrastructure-overview.md#automated-dependency-updates) for the full setup. All PRs require manual review.

## Subsystem Documentation

- [Infrastructure Components](infrastructure-overview.md) — Traefik, cert-manager, Route53 DNS-01, Flux bootstrap, RBAC, CI pipeline details
- [Applications Overview](apps-overview.md) — All 30+ services, service types, Headlamp, migrations, adding new services
- [Monitoring Stack](monitoring.md) — Prometheus, Grafana, PVE exporter, dashboards
- [Servarr Media Stack](servarr.md) — Transmission (WireGuard VPN), Sonarr, Radarr, Prowlarr, Bazarr, Overseerr
- [TrueNAS Gate](truenas-gate.md) — Availability proxy for NAS-dependent services
- [NAS Storage Node](nas-k3s.md) — NixOS bare-metal NAS host as k3s worker (migrated from TrueNAS CORE 2026-07-27), NFS-dependent service scheduling, offline behaviour
- [GPU Worker Node](gpu-k3s.md) — Ubuntu host with NVIDIA GPU joined as k3s worker, NVIDIA device plugin, RuntimeClass, Ollama deployment
- [Shared PostgreSQL](postgres.md) — The single `apps/postgres` instance behind Authentik, Immich and Garden: image choice, adding a database, NetworkPolicy allow-list, backups
- [Immich](immich.md) — Photo management with ML, PostgreSQL, Valkey, database backups
- [Config Backups](config-backups.md) — nightly SQLite-consistent backups of the six servarr/Jellyfin/Plex config PVCs across two CronJobs, plus the July 2026 zvol-recovery record and restore runbook
- [NAS App Tier Migration](nas-app-tier-migration.md) — the #800 cutover runbook that moved Plex and Jellyfin to `k3s` on a soft NFS mount
- [Forgejo](forgejo.md) — Self-hosted Git forge, SQLite/PVC layout, upgrade runbook, Actions OIDC and ephemeral runners
- [Forgejo Backups](forgejo-backups.md) — Two-stage backup design (local + offsite), restore runbook
- [Authentik SSO](authentik.md) — ForwardAuth middleware, protected services, Grafana proxy auth
- [Flux Notifications](notifications.md) — Slack alerting for reconciliation failures, Grafana annotations for successful deployments
- [ghcr-auth.md](ghcr-auth.md) — GHCR auth via static PAT + SOPS: bootstrap, PAT rotation, and per-namespace pattern
- [Container Registry](registry.md) — self-hosted zot registry at `registry.home.bstjohn.net`: auth model, Authentik OIDC UI, retention/GC, rotation
- [Forgejo Mirroring](forgejo-mirroring.md) — Push mirrors from in-cluster Forgejo to GitHub for DR, mirror direction rules, PAT rotation
- [Forgejo Actions](forgejo-actions.md) — In-cluster forgejo-runner with a Docker-in-Docker sidecar, offline registration, runner labels
- [Claws Automation](claws-automation.md) — How the Claws agent manages issues, PRs, and labels in this repo
- [Standing Requirements](requirements.md) — Cross-cutting owner constraints that don't belong to a single subsystem doc
- [Agent notes](agent-notes.md) — Verified host and operator gotchas future agents should know before manual debugging

### Public snapshot

This repo is mirrored to a public GitHub repository. `README.public.md` replaces `README.md` there and must be updated by hand whenever `README.md` changes.
