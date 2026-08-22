# fleet-infra

Complete GitOps configuration for a three-node k3s homelab cluster, managed by Flux CD. This monorepo contains both infrastructure platform components (`clusters/`) and application manifests (`apps/`). All changes land on `main` via Pull Request; Flux automatically reconciles the cluster within about a minute. The manifests here are specific to the author's hardware, DNS zone, and NAS, so this repo is a reference rather than a deployable template.

## Repository Structure

```
fleet-infra/
├── clusters/my-cluster/               # Flux CD cluster configuration
│   ├── flux-system/                   #   Flux bootstrap (controllers, GitRepository, root Kustomization)
│   │   ├── gotk-components.yaml       #     Flux controllers
│   │   ├── gotk-sync.yaml             #     GitRepository + root Kustomization
│   │   └── notifications.yaml         #     Slack alerting
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
│   ├── wildcard-home-cert.yaml        #   Shared TLS cert
│   └── ...                            #   30+ service directories
│
├── migrations/                        # Secret generation Jobs (separate Kustomization)
│
├── .github/workflows/ci.yml           # CI pipeline
├── Taskfile.yaml                      # Local validation + cluster operations
├── renovate.json                      # Automated dependency updates
└── .yamllint                          # YAML linting rules
```

## Reconciliation Layers

Flux reconciles four Kustomizations in dependency order from a single Git source, polling `main` roughly once a minute:

```
infrastructure   → cert-manager, godaddy-webhook, traefik
                   (plus HelmRepository sources for prometheus-community, headlamp, nvidia-device-plugin)

config           → ClusterIssuers, wildcard certificate, RBAC   (dependsOn: infrastructure)
migrations       → secret-generating Jobs                        (dependsOn: infrastructure)
                   (runs in parallel with config, not sequentially after it)

apps             → all application services                     (dependsOn: config + migrations)
```

The explicit root `clusters/my-cluster/kustomization.yaml` is a safeguard that stops Flux from auto-discovering subdirectories and bypassing the `dependsOn` chain — without it, Flux could try to apply Certificate resources before cert-manager's CRDs exist.

## Cluster Layout

The cluster has three nodes:

- A control-plane node that also runs Traefik's LoadBalancer.
- The NAS host itself (NixOS), joined as a worker labelled `node-role.kubernetes.io/storage=true`, used for NFS-backed services.
- An NVIDIA GPU worker labelled `node-role.kubernetes.io/gpu=true`, used for Ollama and Whisper (`runtimeClassName: nvidia`, `nvidia.com/gpu: 1`).

| Class | When to use | Survives NAS offline | Examples |
|-------|-------------|---------------------------|----------|
| `local-path` | Infrastructure, config, databases | Yes | gatus, monitoring |
| NFS | Large media/data | No (pod evicted after ~5 min) | transmission downloads, sonarr/radarr media, immich photos |

## Conventions

### Shared wildcard certificate

A single `Certificate` resource in `apps/wildcard-home-cert.yaml` covers the home domain, and every Ingress references `secretName: wildcard-home-tls` with `ingressClassName: traefik-traefik`. Per-service certificates are banned: DNS-01 validation creates an `_acme-challenge.<service>` TXT record, which makes that subdomain exist as an empty non-terminal in DNS and causes the wildcard record to be skipped for that specific name.

### SSO

Authentik provides authentication for services in two ways: ForwardAuth (a three-`Middleware` Traefik chain) for services with no native auth support, and OIDC for services that support it natively. Providers, applications, groups, and policy bindings are all declared as Authentik blueprints in a ConfigMap rather than configured by hand in the UI.

### Image pinning

All container images are pinned to explicit tags — never `:latest`. Renovate opens update PRs for Helm charts, container images, and, via custom regex managers, the versions of tools used in CI.

## Secrets

Nothing is committed to Git in plaintext. Secrets are handled one of three ways: created imperatively with `kubectl create secret`, generated by the idempotent Jobs under `migrations/`, or committed as SOPS/age-encrypted `*.enc.yaml` files that Flux's `kustomize-controller` decrypts at reconcile time using an age key that only exists in-cluster. The age recipients (public keys) live in `.sops.yaml`; the corresponding private key is never stored in Git.

## Local Validation

From a clone of this repository, the following work without cluster access:

```
task validate   # yamllint + kustomize build + kubeconform + repo-consistency checks
task lint
task kustomize-validate
task kubeconform
```

Prerequisites: `task`, `yamllint`, `kustomize`, `kubeconform`. The cluster-facing targets (`task status`, `task reconcile`, `task logs`, `task diff`) require kubeconfig access to the author's cluster and will not work from a clone.

## CI

Pull requests run a set of blocking and non-blocking checks. Workflow triggers are disabled in this public snapshot, so nothing runs here.

| Job | Purpose | Blocking |
|-----|---------|----------|
| `yaml-lint` | YAML syntax/formatting (yamllint) | Yes |
| `kustomize-validate` | All overlays compile | Yes |
| `kubeconform` | Schema validation (K8s + Flux CRDs) | Yes |
| `security-scan` | kubesec score check (fails on critical) | Yes |
| `image-scan` | Trivy CRITICAL CVEs on changed images (PR only) | Yes |
| `secret-detection` | Blocks hardcoded secrets (gitleaks) | Yes |
| `kustomization-completeness` | Verifies all service dirs listed in parent kustomization.yaml | Yes |
| `renovate-check` | Validates `renovate.json` syntax | Yes |
| `trivyignore-check` | Validates `.trivyignore` governance (expiry dates, format, upstream links) | Yes |
| `ingress-uniqueness` | Verifies no two Ingress/IngressRoute resources claim the same hostname | Yes |
| `kustomize-diff` | Posts rendered manifest diff as PR comment | No |
| `image-verify` | Verifies container images exist in their registries | No |

## Documentation

- [docs/OVERVIEW.md](docs/OVERVIEW.md) — architecture, key patterns, and links to every subsystem doc
- [docs/infrastructure-overview.md](docs/infrastructure-overview.md) — Traefik, cert-manager, GoDaddy webhook, Flux bootstrap, RBAC
- [docs/apps-overview.md](docs/apps-overview.md) — all application services, service types, adding new services
- [docs/monitoring.md](docs/monitoring.md) — Prometheus, Grafana, PVE exporter, dashboards
- [docs/servarr.md](docs/servarr.md) — media automation stack
- [docs/immich.md](docs/immich.md) — photo management
- [docs/config-backups.md](docs/config-backups.md) — config PVC backups and restore runbook
- [docs/authentik.md](docs/authentik.md) — SSO
- [docs/ghcr-auth.md](docs/ghcr-auth.md) — GHCR pull auth via static PAT + SOPS
- [docs/nas-k3s.md](docs/nas-k3s.md) — NAS storage node
- [docs/gpu-k3s.md](docs/gpu-k3s.md) — GPU worker node
- [docs/truenas-gate.md](docs/truenas-gate.md) — availability proxy for NAS-dependent services
- [docs/notifications.md](docs/notifications.md) — Flux Slack notifications
- [CLAUDE.md](CLAUDE.md) — repository conventions and workflow reference
