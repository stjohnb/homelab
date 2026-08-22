# Infrastructure Components

Platform infrastructure for a k3s cluster managed by Flux CD. This document covers the `clusters/` directory: Flux bootstrap, infrastructure Helm releases, certificates, RBAC, and the CI pipeline. For the main entry point, see [OVERVIEW.md](OVERVIEW.md).

## Repository Structure

```
clusters/my-cluster/
├── flux-system/                        # Flux CD bootstrap (auto-generated)
│   ├── gotk-components.yaml            # Flux controllers (v2.7.5)
│   ├── gotk-sync.yaml                  # GitRepository + root Kustomization
│   ├── notifications.yaml              # Slack alerting config
│   └── kustomization.yaml
│
├── infrastructure/                     # Layer 1: Platform components
│   ├── cert-manager/                   # TLS certificate automation
│   ├── godaddy-webhook/                # DNS-01 solver for cert-manager
│   ├── traefik/                        # Ingress controller
│   ├── prometheus-community/           # HelmRepository source for kube-prometheus-stack
│   ├── headlamp/                       # HelmRepository source for Headlamp (app-layer HelmRelease)
│   ├── nvidia-device-plugin/           # HelmRepository source for NVIDIA device plugin (app-layer HelmRelease)
│   └── kustomization.yaml
│
├── config/                             # Layer 2: Cluster configuration (depends on infrastructure)
│   ├── certificates/                   # ClusterIssuers + wildcard cert
│   ├── rbac/                           # Read-only kubectl access
│   └── kustomization.yaml
│
├── kustomization.yaml                  # Explicit resource list for root Flux Kustomization
├── infrastructure-kustomization.yaml   # Flux Kustomization → infrastructure/
├── config-kustomization.yaml           # Flux Kustomization → config/ (dependsOn: infrastructure)
├── migrations-kustomization.yaml       # Flux Kustomization → ./migrations (dependsOn: infrastructure)
└── apps-kustomization.yaml             # Flux Kustomization → ./apps (dependsOn: config + migrations)
```

## Architecture

### Reconciliation Layers

Flux reconciles three layers in dependency order:

```
Layer 1: infrastructure  (10m interval, retryInterval: 1m, healthChecks: 3 HelmReleases, timeout: 5m)
    └── cert-manager, godaddy-webhook, traefik

Layer 2: config          (10m interval, retryInterval: 1m, dependsOn: infrastructure, wait: true, timeout: 5m)
    └── certificates (ClusterIssuers, wildcard cert), RBAC

Layer 2: migrations      (1m interval, dependsOn: infrastructure, prune: true, path: ./migrations)
    └── Jobs: auto-generate secrets in authentik-secrets, headlamp-oidc, etc.
    └── (parallel with config — depends on infrastructure only)

Layer 3: apps            (1m interval, dependsOn: config + migrations, prune: true, path: ./apps)
    └── All application services → default namespace
```

The `config` layer explicitly depends on `infrastructure`, ensuring cert-manager is running before ClusterIssuers and Certificates are created. The `migrations` layer also depends on `infrastructure` and runs in parallel with `config` — it populates secrets needed by application pods but does not require certificates. The `apps` layer depends on both `config` and `migrations`, ensuring both certificates and secrets are ready before application deployments start. All layers use the same Git source (`flux-system`).

The `retryInterval: 1m` on infrastructure and config layers handles a known race condition: when a new Git revision triggers simultaneous reconciliation of all layers, the `config` layer's `dependsOn` check can pass based on infrastructure's stale Ready status from a previous reconciliation while cert-manager CRDs are being replaced. The short retry ensures recovery within a minute rather than waiting the full 10-minute interval.

### Why infrastructure uses healthChecks instead of wait

`wait: true` health-gates every object in the inventory, including the six `HelmRepository` sources. On 2026-08-15 a CoreDNS upstream failure (Tailscale MagicDNS at `100.100.100.100` timing out) made `jetstack` and `external-secrets` (since removed) fail their index fetch, which timed the layer out after 5m and cascaded `DependencyNotReady` to `config`, `migrations`, and `apps` even though all HelmReleases were healthy. The layer now health-gates only on the three HelmReleases (`cert-manager`, `godaddy-webhook`, `traefik`), so chart-index fetch failures no longer halt the pipeline. Gate only on components something actually consumes — the unused External Secrets Operator was removed in part because an idle component in this list could stall every app in the cluster. When adding a new infrastructure HelmRelease, add it to the `healthChecks` list in `clusters/my-cluster/infrastructure-kustomization.yaml`, and never add HelmRepositories there.

The same underlying cause recurred two days later in a different form: from 2026-08-15 21:17 UTC to 2026-08-17 09:16 UTC (~35h), every `HelmRepository` failed with `server misbehaving` because the CoreDNS pod (6d16h old) was still forwarding to a resolv.conf snapshot from before the node's NetworkManager-managed `/etc/resolv.conf` was regenerated. Fixed with `kubectl rollout restart deployment coredns -n kube-system`. CoreDNS's upstream cannot be pinned from this repo: a `coredns-custom` ConfigMap `*.override` file adding a second `forward` directive fails with `plugin/forward: this plugin can only be used once per Server Block`, and a `*.server` file declaring a second `.:53` block fails with a duplicate-zone error. The durable fix — running k3s with a static `--resolv-conf` instead of the node's mutable file — belongs in `St-John-Software/nixos-config`, not here. See [docs/monitoring.md](monitoring.md#cluster-dns) for the detection added in response (Grafana rules + a Gatus DNS probe).

### Root Kustomization Resource List

The explicit `clusters/my-cluster/kustomization.yaml` is an architectural safeguard. Without it, the root `flux-system` Kustomization would auto-discover all subdirectories — including `infrastructure/` and `config/` — and apply their resources directly, bypassing the `dependsOn` chain. This caused production failures when cert-manager CRDs were unavailable: the root Kustomization attempted to apply Certificate resources without waiting for the infrastructure layer. The explicit resource list ensures the root Kustomization only manages Flux bootstrap components and the layer Kustomization definitions, leaving each layer's resources to be reconciled through the proper dependency chain.

### Git Source

A single GitRepository (`flux-system`) points to `St-John-Software/fleet-infra`, branch `main`, polling every 1 minute. Authenticated via SSH deploy key (`flux-system` secret). All three reconciliation layers use this source.

### Namespace Layout

| Namespace | Contents |
|-----------|----------|
| `flux-system` | Flux controllers, GitRepositories, HelmRepositories, HelmReleases, Kustomizations |
| `cert-manager` | cert-manager pods, GoDaddy webhook, `godaddy-api-key` secret |
| `traefik` | Traefik ingress controller |
| `default` | Application workloads (including Headlamp, kube-prometheus-stack, nvidia-device-plugin's HelmRelease object), wildcard TLS certificate, readonly RBAC ServiceAccount, `ghcr-pull` dockerconfigjson Secret (decrypted from SOPS) |
| `kube-system` | nvidia-device-plugin DaemonSet (installed there via the HelmRelease's `targetNamespace: kube-system`) |

Infrastructure HelmReleases are defined in the `flux-system` namespace with `targetNamespace` pointing to the component's namespace. App-layer HelmReleases (Headlamp, kube-prometheus-stack, nvidia-device-plugin) are defined under `apps/` and, despite the `metadata.namespace` written in their YAML, always end up as `default`-namespace objects at apply time — the `apps-kustomization.yaml` Flux Kustomization sets `targetNamespace: default`, which (like `kustomize edit set namespace`) overrides every resource's namespace unconditionally, including ones that already declare one. `apps/nvidia-device-plugin/release.yaml` declares `namespace: flux-system`, but `kubectl get helmrelease -A` confirms the live object is actually in `default`; only its own `spec.targetNamespace: kube-system` (a separate field controlling where the chart's rendered resources go) is respected as written. `sourceRef` fields are exempt from this override, which is why the HelmRelease can still resolve its HelmRepository in `flux-system` regardless of which namespace the HelmRelease itself lands in.

## Infrastructure Components

### Traefik (Helm chart `30.x`)

Ingress controller deployed as a LoadBalancer service.

- **Source file**: `infrastructure/traefik/release.yaml`
- **Helm repo**: `https://traefik.github.io/charts`
- **LoadBalancer IP**: `192.168.0.251`
- **Ports**: 80 (HTTP, redirects to HTTPS), 443 (HTTPS with TLS) — the only two entryPoints; nothing on the NAS host serves HTTP/VNC any more.
- **IngressClass**: Default (auto-created by Traefik)
- **Access logging**: Enabled in JSON format, written to stdout (viewable via `kubectl logs -n traefik`). Sensitive headers (`Authorization`, `Cookie`, `Set-Cookie`) are redacted. All standard fields (method, path, status, duration) are kept. Useful headers (`User-Agent`, `Content-Type`, `X-Forwarded-For`, `X-Real-Ip`, `Host`, `Accept`, `Referer`) are explicitly included; all others are dropped.
- **Key values**:
  - `providers.kubernetesIngress.enabled: true`
  - `providers.kubernetesIngress.publishedService.enabled: true`
  - HTTP→HTTPS redirect via `ports.web.redirectTo.port: websecure`

### cert-manager (Helm chart `1.14.x`)

Automated TLS certificate lifecycle management.

- **Source file**: `infrastructure/cert-manager/release.yaml`
- **Helm repo**: `https://charts.jetstack.io` (as `jetstack`)
- **CRD handling**: Belt-and-suspenders approach — both `crds: CreateReplace` (Flux installs CRDs from the chart's `crds/` directory before each upgrade) and `installCRDs: true` (Helm installs CRDs as template resources tracked in the release manifest). Both are required: without `installCRDs`, Helm's three-way merge deletes CRDs during upgrades because they appear in the old manifest but not the new one.
- **Key values**:
  - `installCRDs: true`
  - `global.leaderElection.namespace: cert-manager`

### GoDaddy Webhook (Helm chart `1.x`)

DNS-01 challenge solver enabling cert-manager to validate domain ownership via GoDaddy DNS API.

- **Source file**: `infrastructure/godaddy-webhook/release.yaml`
- **Helm repo**: `https://fred78290.github.io/cert-manager-webhook-godaddy`
- **Depends on**: `cert-manager` HelmRelease
- **API group**: `acme.bstjohn.net`
- **RBAC**: Custom ClusterRole/ClusterRoleBinding in `infrastructure/godaddy-webhook/rbac.yaml` grants the `cert-manager-cert-manager` ServiceAccount permission to create resources in the `acme.bstjohn.net` API group

### Headlamp HelmRepository (infrastructure source only)

The Headlamp HelmRelease lives in `apps/headlamp/` (deployed to the `default` namespace), but its **HelmRepository source is in `clusters/my-cluster/infrastructure/headlamp/source.yaml`** — placing it in the `flux-system` namespace.

This split is required because the `apps-kustomization.yaml` sets `targetNamespace: default`, which forces every resource in the `apps/` tree into the `default` namespace — including any `HelmRepository` defined there. Flux's source controller looks for HelmRepository objects in `flux-system` when creating HelmCharts, so a repository in `default` cannot be found and the HelmRelease fails with `SourceNotReady`.

**Rule**: Any HelmRepository used by a HelmRelease must reside in `flux-system`. Infrastructure HelmReleases (cert-manager, godaddy-webhook, traefik) are defined in `flux-system` already, so this is natural. App-layer HelmReleases (Headlamp, kube-prometheus-stack) are defined in `default`, so their HelmRepository sources must be kept in `infrastructure/` to land in `flux-system`.

The HelmRelease itself (and its RBAC) remains in `apps/headlamp/`. See [apps-overview.md](apps-overview.md) for full Headlamp configuration.

### prometheus-community HelmRepository

`clusters/my-cluster/infrastructure/prometheus-community/` contains the HelmRepository source for `kube-prometheus-stack`. Same rationale as Headlamp above — the HelmRelease is in `apps/monitoring/` (default namespace), so its source must be in infrastructure to land in `flux-system`.

### GHCR Pull Authentication

A static GitHub PAT is stored as a SOPS-encrypted `dockerconfigjson` Secret at `apps/ghcr-pull-secret.enc.yaml`. Flux's `kustomize-controller` decrypts at reconcile time using the age key in `flux-system/sops-age`. The decryption block lives on `clusters/my-cluster/apps-kustomization.yaml`. See [ghcr-auth.md](ghcr-auth.md) for one-time setup, PAT rotation, and per-namespace usage. External Secrets Operator was installed for an earlier GitHub-App-based variant of this and was removed on 2026-08-19 (issue #860) once it had zero consumers — do not reintroduce ESO for GHCR auth.

## TLS Certificate Configuration

Located in `config/certificates/`.

### ClusterIssuers

Two ACME issuers using DNS-01 challenges via the GoDaddy webhook:

| Name | ACME Server | Use Case |
|------|-------------|----------|
| `letsencrypt-production` | `acme-v02.api.letsencrypt.org` | Production certificates |
| `letsencrypt-staging` | `acme-staging-v02.api.letsencrypt.org` | Testing (untrusted) |

Both configured identically:
- **Email**: `brendan@bstjohn.net`
- **Solver**: `dns01.webhook` with `groupName: acme.bstjohn.net`, `solverName: godaddy`
- **DNS zone selector**: `bstjohn.net`
- **TTL**: 600 seconds
- **API key reference**: `godaddy-api-key` secret in `cert-manager` namespace (keys: `key`, `secret`)

### Wildcard Certificate

- **Name**: `wildcard-home` (in `default` namespace)
- **Secret**: `wildcard-home-tls`
- **Issuer**: `letsencrypt-production` (ClusterIssuer)
- **DNS names**: `*.home.bstjohn.net`, `home.bstjohn.net`
- **File**: `apps/wildcard-home-cert.yaml`

## RBAC (Read-Only Access)

Located in `config/rbac/`. See [config/rbac/README.md](../clusters/my-cluster/config/rbac/README.md) for setup instructions.

Provides read-only cluster access to enforce GitOps discipline:
- **ServiceAccount**: `readonly-user` in `default` namespace
- **ClusterRole**: `read-only-cluster-viewer` — allows `get`/`list`/`watch` on explicitly enumerated resources across 12 API groups (core, apps, batch, autoscaling, networking, storage, rbac, policy, cert-manager, Flux CD, Traefik, apiextensions), plus `pods/log` and `pods/portforward`. **Secrets are excluded** from the core API group to prevent credential exposure.
- **Token**: Long-lived token via `readonly-user-token` Secret (type `kubernetes.io/service-account-token`)
- **Pod exec**: Disabled by default (commented out in ClusterRole)

## Slack Notifications

Defined in `flux-system/notifications.yaml`. See [notifications.md](notifications.md) for details.

- **Provider**: Slack, channel `lab`, secret `flux-slack-webhook`
- **Source alerts** (info severity): Fires when the `flux-system` GitRepository pulls new revisions
- **Helm upgrade alerts** (info severity, filtered): Fires when HelmRelease upgrades or installs succeed, filtered via `inclusionList` to avoid periodic reconciliation noise
- **Error alerts** (error severity): Fires on reconciliation failures for all Kustomizations (`flux-system`, `infrastructure`, `config`, `apps`) and all HelmReleases (`cert-manager`, `godaddy-webhook`, `traefik` in `flux-system`; `headlamp`, `kube-prometheus-stack` in `default`). Also watches HelmRepositories in `infrastructure/` (`headlamp`, `prometheus-community`) since a missing source blocks all downstream HelmReleases.

## Key Patterns

### Adding Infrastructure Components

Each infrastructure component follows a consistent pattern under `infrastructure/<name>/`:

1. `namespace.yaml` — Namespace resource (optional if deploying to existing namespace)
2. `source.yaml` — `HelmRepository` in `flux-system` namespace
3. `release.yaml` — `HelmRelease` in `flux-system` namespace with `targetNamespace`
4. `kustomization.yaml` — Kustomize overlay listing the above files
5. Add the directory to `infrastructure/kustomization.yaml` resources list

All HelmReleases use:
- `install.remediation.retries: 3`
- `upgrade.remediation.retries: 3`
- `interval: 30m` for chart reconciliation
- `chart.spec.interval: 12h` for source polling

**HelmRepository namespace requirement**: All `HelmRepository` objects must be in the `flux-system` namespace — including those for app-layer HelmReleases (Headlamp, kube-prometheus-stack). The `apps-kustomization.yaml` sets `targetNamespace: default`, forcing every resource in `apps/` into `default`. Flux's source controller looks for `HelmRepository` objects in `flux-system` when creating `HelmChart` objects — a repository in `default` cannot be found, producing a `SourceNotReady` error. When adding a new HelmRelease under `apps/`, always create its `HelmRepository` in `infrastructure/` so it lands in `flux-system`.

### Adding Application Services

Application services live in the `apps/` directory of this repository. The `apps` Kustomization deploys everything under `./apps` to the `default` namespace. See [apps-overview.md](apps-overview.md) for service details and patterns.

### Dependency Ordering

Use `dependsOn` in HelmReleases for component dependencies (e.g., godaddy-webhook depends on cert-manager). Use `dependsOn` in Flux Kustomizations for layer dependencies (e.g., config depends on infrastructure).

### Version Pinning

Helm chart versions use semver constraints (`"30.x"`, `"1.14.x"`, `"1.x"`). Flux CD version is managed by re-exporting `gotk-components.yaml`.

All `HelmRepository` resources use `source.toolkit.fluxcd.io/v1` and `HelmRelease` resources use `helm.toolkit.fluxcd.io/v2`.

## CI Pipeline

Defined in `.github/workflows/ci.yml`. Runs on PRs targeting `main` and pushes to `main`. Uses per-branch concurrency groups (`ci-${{ github.ref }}`) with `cancel-in-progress: true` to avoid redundant runs.

### Toolchain: repo-owned via `flake.nix` (PR #754)

The self-hosted NixOS runners provide only a baseline of `nix`, `git`, and `docker` — every tool a workflow shells out to (`yamllint`, `kustomize`, `kubeconform`, `kubesec`, `trivy`, `gitleaks`, `jq`, `curl`, `crane`, `nodejs`, `yq-go`, a `pyyaml`-equipped `python3`) is declared in this repo's own `flake.nix` and entered via `nix develop`, isolated in the nix store. This replaced per-job `apt-get`/curl-a-binary installers and a shared `setup-kustomize` composite action — those installers hardcode `/lib64/ld-linux` and only run on NixOS through the `nix-ld` shim, and installing tools globally on the runner would let one repo's toolchain collide with another's on the same shared pool.

Two devShells in `flake.nix`:
- **`default`** — the full scanner/validator toolchain, used by `yaml-lint`, `kustomize-validate`, `kubeconform`, `security-scan`, `image-scan`, `secret-detection`, `kustomization-completeness`, `ingress-uniqueness`, `gate-netpol`, `image-pull-secrets`, `renovate-check`, `trivyignore-check`, `image-consistency`, `kustomize-diff`, `image-verify`.
- **`scripts`** — just `gh`, for jobs that only talk to the GitHub API: `notify-failures.yml`, `cleanup-actions-storage.yml`, the tag-computation step of `build-arpwatch.yml`, `update-bin-scraper.yml`, and the comment-posting step of `ci.yml`'s `kustomize-diff` job. Kept separate so these don't pay for the scanner toolchain closure.

Every job runs a `Set up Nix` step (`.github/actions/setup-nix`) that puts the runner's Nix on `PATH` and fails loudly if none is found, then either sets `defaults.run.shell` to `nix ... develop ${{ github.workspace }}#<shell> --command bash -euo pipefail {0}` for the whole job, or wraps individual `run:` steps in `nix $NIX_FLAGS develop --command <tool>`. **When adding a new CI dependency, add it to `flake.nix` — never `sudo apt-get install`, never a curl-a-binary installer, and never ask for the tool to be added to the runner's own package set.**

`flake.lock` pins `nixpkgs-unstable` independently of whatever channel the runner hosts are built from; Renovate does not currently update it (not a `HelmRelease` or container image).

A separate workflow (`.github/workflows/build-arpwatch.yml`) builds the custom arpwatch container image on pushes to `main` (path-filtered to `images/arpwatch/**`) and manual dispatch. It uses the same concurrency pattern (`build-arpwatch-${{ github.ref }}`, `cancel-in-progress: true`) and pushes to `ghcr.io/st-john-software/arpwatch` with both a date-SHA tag and `latest`. The `build` job sets `DOCKER_BUILD_RECORD_UPLOAD: false` to prevent `docker/build-push-action@v6` from auto-uploading `.dockerbuild` build-record artifacts, which accumulate against the org-shared 2 GB GitHub Actions storage quota. The image build/push, SBOM attestation, and provenance (all pushed to GHCR, not uploaded as Actions artifacts) are unaffected.

A third workflow (`.github/workflows/cleanup-actions-storage.yml`) runs on a weekly schedule (Monday 04:00 UTC) and on `workflow_dispatch`. It deletes all Actions artifacts and caches via the GitHub API. This is safe because the repo deliberately produces zero artifacts (`DOCKER_BUILD_RECORD_UPLOAD: false` in `build-arpwatch.yml`, no `actions/upload-artifact` anywhere) — deleting everything keeps the repo's footprint against the org-shared 2 GB GitHub Actions storage quota at ~0. The `workflow_dispatch` trigger lets the maintainer run it immediately after merge to clear any pre-existing artifacts.

A fourth workflow (`.github/workflows/update-bin-scraper.yml`) handles automated image bumps for the bin-scraper service. It triggers on `workflow_dispatch` — the bin-scraper repo's Release workflow calls `gh workflow run update-bin-scraper.yml --repo St-John-Software/fleet-infra --field tag=<version>` after pushing a new image — validates the tag format (`YYYYMMDD-N-HASH`), rewrites the image reference in `apps/bin-scraper/deployment.yaml`, and opens a PR via `peter-evans/create-pull-request` on an `automation/bump-bin-scraper-<tag>` branch, labelled `dependencies,auto-bump`. This mirrors production-infra's `bump-app-version.yml` pattern: no native GitHub auto-merge (`gh pr merge --auto` races GitHub's mergeability computation and is unreliable with no required status checks on `main`) — instead the `automation/bump-*` branch prefix and `auto-bump` label mark the PR for Claws' auto-merger, which merges it once `ci.yml` passes. See [Claws Automation](claws-automation.md).

**Authentication — `FLEET_INFRA_VERSION_BUMP`:** a single **org-level** fine-grained PAT secret in the `St-John-Software` organization. The PAT's **repository access is fleet-infra only** — every operation it performs (the `gh workflow run` dispatch from bin-scraper, and the receiving workflow's checkout/push/PR) targets fleet-infra; bin-scraper merely needs to *read* the secret, which the org secret's repository-access selection (`fleet-infra` + `bin-scraper`) provides. PAT permissions: `Actions: Read and write` (dispatch), `Contents: Read and write` and `Pull requests: Read and write` (so the bump branch push and PR are authored by the PAT owner — a `GITHUB_TOKEN`-authored PR does not trigger `pull_request` events, so `ci.yml` would never run on the bump branch and Claws' auto-merger would skip it, since it requires passing checks). Fine-grained PATs expire after at most one year; on expiry the workflow's preflight step fails loudly — rotate by generating a new token with the same scopes and updating the org secret value (no workflow change needed).

### Overlay enumeration (`scripts/overlays.sh`)

Six sites in this repo needed to know the list of kustomize overlays (`apps`, `migrations`, `clusters/my-cluster/infrastructure`, `clusters/my-cluster/config`); before #888, five hardcoded that list separately and only `check-image-pull-secrets.sh` included `migrations` — so the `migrations` overlay was silently excluded from ingress-uniqueness checking, completeness checking, the `kustomize-diff` PR comment, and image scanning/verification. `scripts/overlays.sh` is now the single source of truth: it prints one `<overlay-path>:<effective-default-namespace>` pair per line (the namespace column is empty for infrastructure/config, which set no `targetNamespace`), and every consumer (`check-completeness.sh`, `check-ingress-uniqueness.sh`, `check-image-pull-secrets.sh`, the `kustomize-diff` and `image-verify` steps in `ci.yml`, and `Taskfile.yaml`) reads it via `mapfile -t OVERLAYS < <(./scripts/overlays.sh | cut -d: -f1)` (or without the `cut` when the namespace column is needed) instead of a literal array. **Adding a new Flux Kustomization layer means adding one line to `scripts/overlays.sh` — every check picks it up automatically.** The script must stay executable (`chmod +x`, mode `100755`) or every consumer fails with "Permission denied".

The `image-scan` job's changed-file path filter additionally needed both `migrations/*.yaml` and `migrations/**/*.yaml` patterns — `migrations/job.yaml` sits at the top level of `migrations/` with no subdirectories, and a bare `migrations/**/*.yaml` git pathspec (the `**` requires a following `/`) matches nothing there.

### Jobs

| Job | Tool | Purpose | Blocking |
|-----|------|---------|----------|
| `yaml-lint` | `yamllint` (from `flake.nix`) | Lint all YAML files against `.yamllint` config | Yes |
| `kustomize-validate` | `kustomize build` | Verify all kustomization overlays resolve | Yes |
| `kubeconform` | `kubeconform` (needs `kustomize-validate`) | Validate manifests against K8s + Flux CRD schemas | Yes |
| `security-scan` | `kubesec` (needs `kustomize-validate`) | Security scan of every workload manifest under apps/ (matched by kind, not filename) | Yes |
| `image-scan` | `trivy` (PR only, needs `kustomize-validate`) | Scan changed container images for CRITICAL CVEs | Yes |
| `secret-detection` | `gitleaks` | Check for hardcoded secrets in manifests | Yes |
| `kustomization-completeness` | `yq` + `scripts/check-completeness.sh` | Verify all service dirs listed in parent kustomization.yaml | Yes |
| `ingress-uniqueness` | `yq` + `kustomize` + `scripts/check-ingress-uniqueness.sh` | Verify no two Ingress/IngressRoute resources claim the same hostname | Yes |
| `gate-netpol` | `yq` + `kustomize` + `scripts/check-gate-netpol.sh` | Verify truenas-gate-fronted services allow ingress from the gate | Yes |
| `image-pull-secrets` | `yq` + `kustomize` + `scripts/check-image-pull-secrets.sh` | Verify every `imagePullSecrets` reference resolves to a declared dockerconfigjson Secret in the same overlay | Yes |
| `renovate-check` | `renovate-config-validator` via npx | Validate `renovate.json` syntax | Yes |
| `trivyignore-check` | `scripts/check-trivyignore.sh` | Validate `.trivyignore` governance (expiry dates, format, upstream links) | Yes |
| `image-consistency` | `scripts/check-image-tag-consistency.sh` | Verify no service directory pins the same image to two different tags | Yes |
| `kustomize-diff` | `kustomize` + `gh` (PR only) | Post rendered manifest diff (apps + clusters + migrations) as PR comment | No |
| `image-verify` | `crane` (PR only) | Verify container images exist in their registries | No |

GitHub API calls in CI use `gh`, never `curl -H "Authorization: ..."` — on shared self-hosted runners an argv-passed token is readable by any other local process via `ps auxww` or `/proc/<pid>/cmdline` for the lifetime of the call. `image-verify`'s `crane auth login --password-stdin` (registry auth) follows the same principle: keep tokens off argv, in stdin or the environment instead.

`ci.yml` declares a top-level `permissions: {contents: read}` block (#830), matching every other workflow in the repo — the thirteen read-only jobs above inherit it and get nothing more. `kustomize-diff` (`pull-requests: write`) and `image-verify` (`packages: read`) declare their own job-level `permissions:` blocks that each re-list `contents: read`, because a job-level block **replaces** the workflow-level one rather than merging with it.

All jobs run on `[self-hosted, linux]` runners. The `linux` label ensures jobs are only picked up by Linux runners — without it, a future macOS runner joining the pool could claim Linux-only jobs. The runner pool has two members: `ryzen` (NixOS, GPU box — see [gpu-k3s.md](gpu-k3s.md)) and `beefy-actions`; either can pick up a `[self-hosted, linux]` job.

**`ryzen` `noexec` incident (2026-08-03/04, issue #748) — resolved, host-side fix, predates the flake.nix migration.** Before PR #754, `nixos-config#87` moved the `ryzen` runner's `HOME` and tool cache off the `/run` tmpfs and onto a systemd `StateDirectory` (`/var/lib/github-runner/ryzen-home`, `ryzen-tool`), which mounts `noexec` — so any tool the old workflow had downloaded into `$HOME/.local/bin` failed to execute (`exit code 126` / `EACCES`, coin-flip per job depending on which runner picked it up). Fixed host-side in `nixos-config#94`. Since PR #754, CI no longer downloads tools into `$HOME` at all — everything comes from the nix store via `nix develop` — so this failure mode cannot recur regardless of the `StateDirectory` mount options. Kept here as history in case a `noexec`-shaped failure resurfaces for a different reason.

**CI failures traced to causes outside this repo's manifests (issue #712, closed 2026-08-05):** a single `renovate-check` failure was the self-hosted `ryzen` runner receiving a shutdown signal mid-job during its NixOS rebuild (unrelated to the PR, no code fix possible); a class of permission-denied failures on cached tool downloads was eliminated by the flake.nix migration (PR #754, above); a separate permission-denied class was the Claws automation service wiping the runner's live `_work/_tool` directory mid-job, fixed in `St-John-Software/claws#2328` (2026-08-04), not in this repo. If a CI job fails with no connection to the PR's diff, check whether it reproduces on a re-run before assuming a manifest problem — transient runner-host and cross-repo automation issues have caused several single-occurrence false alarms.

**Security scan exceptions** (allowed negative kubesec scores with justification):
- `apps/servarr/transmission/deployment.yaml` — privileged mode for VPN
- `apps/arpwatch/deployment.yaml` — hostNetwork for ARP monitoring
- `apps/containerd-gc/cronjob.yaml` — privileged containerd socket access
- `apps/forgejo-runner/deployment.yaml` — privileged Docker-in-Docker sidecar for Forgejo Actions

Workload discovery greps for `^kind: (Deployment|StatefulSet|DaemonSet|CronJob|Job)` under `./apps` rather than globbing on filenames, so suffixed files (`deployment-server.yaml`, `cronjob-backup.yaml`) are covered; the job fails if the number of files scored does not match the number discovered.

**Image scanning**: Trivy scans only images changed in the PR diff. Both the main vulnerability DB and the Java DB are pre-downloaded before scanning to avoid per-image download overhead. Private images (e.g., `ghcr.io/st-john-software/*`) are skipped when authentication is unavailable.

### YAML Lint Configuration (`.yamllint`)

- Extends `default` ruleset
- **Ignores**: `clusters/my-cluster/flux-system/gotk-components.yaml` (auto-generated by `flux bootstrap`)
- Line length: 200 max
- Truthy rule: disabled (K8s YAML uses bare `true`/`false`)
- Document start (`---`): not required
- Indentation: 2 spaces

### Schema Validation

`kubeconform` runs in strict mode with `-ignore-missing-schemas` to tolerate CRDs without schemas (cert-manager, Traefik). Flux CRD schemas are pinned to `v2.8.3` and downloaded from `fluxcd/flux2` releases. This is newer than the cluster's installed Flux version (v2.7.5) — Renovate bumps the schema version independently. Using `/latest/` would silently pull schemas from an unpinned Flux version with different CRD fields.

## Task Runner

A [`Taskfile.yaml`](../Taskfile.yaml) ([go-task](https://taskfile.dev/installation/)) provides targets for local validation and common cluster operations. Running `task` with no arguments executes the full validation suite.

| Task | Description |
|------|-------------|
| `task validate` | Run the full CI pipeline locally (lint → kustomize → kubeconform → check-completeness → trivyignore-check → check-ingress-uniqueness → check-image-consistency) |
| `task lint` | Lint all YAML files with yamllint |
| `task kustomize-validate` | Build and validate all kustomize overlays |
| `task kubeconform` | Validate manifests against Kubernetes and Flux CRD schemas |
| `task setup:flux-schemas` | Download/cache Flux CRD schemas for kubeconform (run automatically by `kubeconform` if missing) |
| `task check-completeness` | Verify all service directories listed in parent kustomization.yaml |
| `task trivyignore-check` | Validate `.trivyignore` format, expiry dates, and upstream links |
| `task check-ingress-uniqueness` | Verify no two Ingress/IngressRoute resources claim the same hostname |
| `task check-image-consistency` | Verify no service directory pins the same image to two different tags |
| `task renovate-check` | Validate `renovate.json` syntax + check file coverage against fileMatch patterns |
| `task image-verify` | Verify container image references are pullable (crane) |
| `task reconcile` | Force immediate reconciliation (`flux-system --with-source`) |
| `task status` | Show all Flux resources |
| `task status:hr` | Show HelmRelease status |
| `task status:ks` | Show Kustomization status |
| `task status:sources` | Show all source status |
| `task logs` | Tail all Flux controller logs |
| `task logs:source` | Tail source-controller logs |
| `task logs:kustomize` | Tail kustomize-controller logs |
| `task logs:helm` | Tail helm-controller logs |
| `task suspend` | Suspend reconciliation of all kustomizations |
| `task resume` | Resume reconciliation of all kustomizations |
| `task diff` | Preview what Flux would apply |

Each task checks for required tools (`yamllint`, `kustomize`, `kubeconform`, `yq`, `flux`) via preconditions and prints install instructions if missing. Flux CRD schemas for kubeconform are cached in `.task/` (gitignored).

The `renovate-check` task is **not** part of `validate` — it's a standalone command with different dependencies (npx for syntax validation, python3 for file coverage). It runs two phases: (1) config syntax validation via `npx renovate-config-validator` (gracefully skips if npx is unavailable), and (2) a file coverage check that discovers all Dockerfiles, YAML files with `image:` references, and YAML files with `HelmRelease` resources, then verifies each is matched by at least one Renovate `fileMatch` pattern for the appropriate manager (`dockerfile`, `kubernetes`, or `flux`). Exits non-zero if uncovered files are found.

## Automated Dependency Updates

**Configured but not actually running.** `renovate.json` is present and CI-validated (`renovate-check`), but no Renovate app/runner has ever been installed against this repo — as of the #701 investigation (2026-07-28), `gh api /repos/St-John-Software/fleet-infra/issues?creator=renovate[bot]` returned `[]`, there is no "Dependency Dashboard" issue, and zero PRs in the repo's history have ever been Renovate-authored. `apps/forgejo/deployment.yaml` sat on `14.0.3-rootless` without so much as a patch-bump PR despite newer patch tags existing the whole time — confirming this isn't a fileMatch gap in the config, just a missing installation. Do not assume "Renovate will catch this" for a stale image tag or chart version; until the app is installed, version bumps must be found and proposed manually. Installing/enabling the Renovate app is tracked as separate follow-up work, not fixed by editing `renovate.json`.

Intended design (accurate once Renovate is actually enabled): managed by [Renovate Bot](https://docs.renovatebot.com/). Configuration in `renovate.json`. Renovate was chosen over Dependabot because its native `flux` manager understands `HelmRelease` and `HelmRepository` CRDs, can parse semver range constraints like `"1.14.x"`, and cross-references `HelmRepository` sources to look up available versions.

Renovate's `flux` manager detects `HelmRelease` resources in `clusters/` and `apps/` (fileMatch: `(clusters|apps)/.+\.ya?ml$`) and opens PRs when new chart versions are available. The `kubernetes` manager detects container image references in `apps/` and opens PRs for image updates. Since Helm chart versions use semver range constraints (e.g., `"1.14.x"`), Flux automatically applies patch updates within the range. Renovate handles updates **outside** the current range — bumping `"1.14.x"` to `"1.15.x"` on minor releases, or proposing major version upgrades as separate PRs.

Four `packageRules` group related images into a single PR (`groupName`) so a simultaneous upstream batch release doesn't produce a flood of separate PRs: `linuxserver-images` (all LinuxServer.io servarr images), `immich` (`ghcr.io/immich-app/*`), `authentik` (`ghcr.io/goauthentik/*`), and `monitoring` (exporter images) (#145).

Six `customManagers` (regex-based) track CI tool versions embedded in download URLs and shell variables:

| Custom Manager | Datasource | Files |
|---------------|------------|-------|
| `kubeconform` | `yannh/kubeconform` releases | CI workflow |
| `kubesec` | `controlplaneio/kubesec` releases | CI workflow |
| `trivy` | `aquasecurity/trivy` releases | CI workflow |
| `gitleaks` | `gitleaks/gitleaks` releases | CI workflow |
| `flux-crd-schemas` | `fluxcd/flux2` releases | CI workflow + Taskfile |
| `flux-github-action` | `fluxcd/flux2` releases | CI workflow |

| Behavior | Detail |
|----------|--------|
| Range strategy | `bump` — preserves `x.y.x` range format |
| Major updates | Separate PR with `major-update` label |
| Minor/patch updates | Separate PR with `helm` label |
| CI tool updates | Separate PR with `ci` label |
| Auto-merge | Disabled — all PRs require manual review |
| Ignored paths | `gotk-components.yaml` (managed by `flux bootstrap`) |

## Secrets (Not in Git)

| Secret | Namespace | Purpose |
|--------|-----------|---------|
| `godaddy-api-key` | `cert-manager` | GoDaddy API credentials for DNS-01 challenges |
| `flux-system` | `flux-system` | SSH deploy key for fleet-infra repo (created by Flux bootstrap) |
| `flux-slack-webhook` | `flux-system` | Slack incoming webhook URL |
| `sops-age` | `flux-system` | Age private key used by Flux `kustomize-controller` to decrypt SOPS-encrypted manifests (currently `apps/ghcr-pull-secret.enc.yaml`); created out-of-band, not in Git |
| `ghcr-pull` | `default` | GHCR dockerconfigjson — applied from SOPS-encrypted manifest `apps/ghcr-pull-secret.enc.yaml`; static PAT, rotated manually |
| `grafana-slack-webhook` | `default` | Grafana Slack webhook URL |
| `grafana-annotations-token` | `flux-system` | Grafana service account token (Editor role) for Flux deployment annotations |
| `readonly-user-token` | `default` | Auto-populated by Kubernetes from ServiceAccount |

## DNS

Wildcard DNS records in GoDaddy point to the Traefik LoadBalancer:

- `*.home.bstjohn.net` → `192.168.0.251` (A record)
- `home.bstjohn.net` → `192.168.0.251` (A record)

### Remote access over Tailscale

There is **no Tailscale MagicDNS/split-DNS override** for `home.bstjohn.net` — tailnet
devices resolve `*.home.bstjohn.net` to `192.168.0.251` via the same public GoDaddy records
as everything else. Since `192.168.0.251` is a private LAN address, off-LAN Tailscale devices
can only reach it through a **subnet router** advertising `192.168.0.0/24`. If no approved
subnet router for that CIDR is online, all `*.home` services become unreachable from off-LAN
tailnet devices (LAN access is unaffected).

Subnet routers advertising `192.168.0.0/24` (approve each in the Tailscale admin console →
Machines → *node* → route settings):

- **Home Assistant** (`homeassistant`, tailnet `100.69.220.140`, LAN `192.168.0.89`) — also an exit node.
- **k3s node** (`k3s`, tailnet `100.78.7.18`, LAN `192.168.0.251`) — added as an always-on standby via
  `sudo tailscale set --advertise-routes=192.168.0.0/24`.

Tailscale uses these as **failover, not load-balancing**: one is primary, and if it drops the
other is promoted automatically. Making the always-on k3s node a second router removes the
single point of failure (an HA outage on 2026-06-20 took `*.home` remote access down until noticed).

## Cluster Details

| Property | Value |
|----------|-------|
| Cluster IP | `192.168.0.251` |
| Kubernetes | k3s (bootstrapped with `--disable traefik`) |
| Flux CD | v2.7.5 |
| DNS domain | `home.bstjohn.net` |
| GitHub org | `St-John-Software` |

### The main `k3s` node's host OS is unmanaged

Unlike `k3s-nas` and `ryzen`, which are provisioned declaratively from the sibling `nixos-config` repo (see [nas-k3s.md](nas-k3s.md), [gpu-k3s.md](gpu-k3s.md)), the main node (`k3s`, Debian 12, `192.168.0.251`) has no config repo of its own — nothing outside this cluster's own manifests declares its host state. Any fix applied directly on that host (sysctls, packages, `/etc` files) is undeclared and silently reverts on a reinstall. Concretely: after #800 moved Jellyfin onto `k3s`, it crash-looped because Debian's kernel default `fs.inotify.max_user_instances=128` was too low (the NixOS nodes already sit at 524288); the fix — `fs.inotify.max_user_instances=1024` in `/etc/sysctl.d/90-inotify-instances.conf` — was applied by hand on the host and is **not** captured anywhere in Git (#805). Treat any future "fix it on the `k3s` host" step the same way: it's a known gap, not a resolved one, until this node gets its own declarative provisioning (or the fix is moved into a cluster-level mechanism, e.g. a privileged DaemonSet).

## Known Network Alerts

### UniFi IDS: "ET SCAN Potential SSH Scan OUTBOUND" (SID 2003068)

The UniFi IDS/IPS periodically raises a **High-severity Intrusion Prevention** threat: signature `ET SCAN Potential SSH Scan OUTBOUND` (Signature ID `2003068`), Direction *Outgoing*, Service *SSH*, Action *Allow*.

**This is a benign false positive.** Flux's `source-controller` polls the Git repository over SSH every 60 seconds (`clusters/my-cluster/flux-system/gotk-sync.yaml`: `url: ssh://git@github.com/...`, `interval: 1m0s`). `github.com` resolves to a rotating pool of anycast IPs, so repeated outbound port-22 connections to several distinct destinations within a two-minute window trip Suricata's outbound-SSH-scan heuristic (threshold ~5 connections / 120s by source). Action is *Allow* — traffic is logged only, never blocked, and Flux reconciliation is unaffected.

**Before dismissing:** confirm the threat's *source* IP is a cluster node (e.g. `192.168.0.251`) and the *destination* resolves to `github.com`. If the source is a different host, treat it as a genuine outbound-scan indicator and investigate that host instead.

**To silence (UniFi-side, not managed by this repo):** add a Threat Management allow-list / suppression entry in the UniFi Network console for signature `2003068`, scoped to the cluster node's IP as the source.
