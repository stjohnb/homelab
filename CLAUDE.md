# Instructions for AI Assistants (Claude Code)

This file contains important context and guidelines for AI assistants working with this repository.

## Where to Read First

For full context before planning or implementing changes, read **[`docs/OVERVIEW.md`](docs/OVERVIEW.md)**. It covers architecture, key patterns, and links to dedicated docs for each subsystem (monitoring, servarr, authentik, immich, GPU node, etc.).

## Repository Overview

- **Purpose**: Complete GitOps configuration for k3s cluster (infrastructure + applications)
- **GitOps**: Managed by Flux CD (automatic deployment)
- **Namespace**: Infrastructure in dedicated namespaces, apps in `default` namespace
- **Structure**: Monorepo — infrastructure in `clusters/`, applications in `apps/`

### Public snapshot

This repo is mirrored to a public GitHub repository. The root `README.public.md` is published there as `README.md` and is **maintained by hand** — when you change `README.md`, check whether `README.public.md` needs the same change. Never add anything to `README.public.md` that links to `ideas/`, `.claude/`, `docs/claws-automation.md`, `BLOG_IDEAS.md`, or `HOMELAB_IDEAS.md` (all scrubbed from the snapshot), and never put credentials or key material in any tracked file.

## CRITICAL: Flux CD Workflow

**This cluster is managed by Flux CD. Changes MUST be merged to main via Pull Request to take effect.**

### Correct Workflow
```bash
# 1. Create a feature branch
git checkout -b feat/description-of-change

# 2. Make changes to manifests

# 3. Commit changes
git add .
git commit -m "Description of change

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"

# 4. Push to feature branch
git push -u origin feat/description-of-change

# 5. Create Pull Request
gh pr create --title "Description" --body "Details of changes"

# 6. Review and merge PR (via GitHub web UI or CLI)
# Flux will automatically reconcile after merge (~1min)

# 7. Monitor deployment
kubectl get pods -w

# 8. Optional: Force immediate reconciliation
flux reconcile kustomization flux-system --with-source
```

### Branch Protection
- **All changes require Pull Requests** — Direct pushes to `main` are blocked
- This ensures code review and maintains audit trail
- Even admins must use PRs

### DO NOT use kubectl apply directly
```bash
# WRONG - changes will be overwritten by Flux
kubectl apply -f service.yaml
```

### Exception
Only use `kubectl apply` for:
- Debugging/testing before commit
- Creating secrets (not stored in Git)
- Emergency fixes (but still commit afterward!)

## Repository Structure

```
fleet-infra/
├── clusters/my-cluster/           # Flux CD cluster configuration
│   ├── flux-system/               # Flux bootstrap components
│   ├── infrastructure/            # cert-manager, traefik, godaddy-webhook
│   ├── config/                    # certificates, RBAC
│   ├── kustomization.yaml         # Root resource list
│   ├── apps-kustomization.yaml    # Flux Kustomization → ./apps
│   ├── infrastructure-kustomization.yaml
│   └── config-kustomization.yaml
├── apps/                          # Application manifests (deployed to default ns)
│   ├── kustomization.yaml         # Lists all service directories
│   ├── priority-classes.yaml
│   ├── wildcard-home-cert.yaml
│   ├── bin-scraper/
│   ├── gatus/
│   ├── homepage/
│   ├── immich/
│   ├── ... (all service dirs)
│   └── servarr/
├── docs/                          # Documentation
├── ideas/                         # Feature ideas
├── .github/workflows/ci.yml       # CI pipeline
├── Taskfile.yaml                  # Local validation + cluster operations
└── renovate.json                  # Automated dependency updates
```

## CI/Automated Testing

**All Pull Requests are automatically validated before merge.**

### What Gets Checked

1. **YAML Linting** — Validates syntax and formatting (yamllint)
2. **Kustomize Build** — Ensures all manifests compile successfully
3. **Kubernetes Validation** — Schema validation with kubeconform (offline, with Flux CRD schemas)
4. **Security Scanning** — Fails on critical security issues (kubesec score < 0)
5. **Image Vulnerability Scanning** — Scans container images for CRITICAL CVEs (Trivy, PR only)
6. **Secret Detection** — Blocks PRs with hardcoded secrets
7. **Kustomize Diff** — Posts rendered manifest diff as PR comment (non-blocking)
8. **Image Reference Verification** — Verifies new/changed container image references are pullable (crane, PR only, non-blocking)

### Running Checks Locally

```bash
# Full validation (requires yamllint, kustomize, kubeconform)
task validate

# Or individually:
task lint
task kustomize-validate
task kubeconform
```

### CI Configuration
- Workflow: `.github/workflows/ci.yml`
- Linting rules: `.yamllint`

## DNS and Certificates - IMPORTANT

### Current Domain Setup
- **Primary domain**: `*.home.bstjohn.net` → 192.168.0.251
- **Wildcard DNS**: Configured in GoDaddy

### Certificate Management

**Single Wildcard Certificate** — defined in `apps/wildcard-home-cert.yaml`.

**For new services**, use this ingress template:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-service
  annotations: {}  # NO cert-manager.io/cluster-issuer annotation!
spec:
  ingressClassName: traefik-traefik
  tls:
    - hosts:
        - my-service.home.bstjohn.net
      secretName: wildcard-home-tls  # Shared wildcard cert
  rules:
    - host: my-service.home.bstjohn.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-service
                port:
                  number: 8080
```

**Key Points**:
- Use `wildcard-home-tls` secret (already exists)
- Never add `cert-manager.io/cluster-issuer` annotation to ingresses
- Never create per-service Certificate resources
- All services share one wildcard certificate

### Why This Matters: DNS Wildcard Issue

Per-service TLS certificates create `_acme-challenge.service.home.bstjohn.net` TXT records that make subdomains "exist" as empty non-terminals, causing the wildcard to be ignored for those specific subdomains.

## Adding Infrastructure Components

Infrastructure lives under `clusters/my-cluster/infrastructure/`. Each component follows:
1. `namespace.yaml` — Namespace resource
2. `source.yaml` — HelmRepository in flux-system namespace
3. `release.yaml` — HelmRelease in flux-system namespace with targetNamespace
4. `kustomization.yaml` — Kustomize overlay listing the above
5. Add directory to `clusters/my-cluster/infrastructure/kustomization.yaml`

## Adding Application Services

Applications live under `apps/`. Each service directory contains its manifests.

1. **Create service directory**: `mkdir -p apps/my-service`
2. **Create manifests** (deployment.yaml, service.yaml, ingress.yaml, kustomization.yaml)
3. **Use wildcard certificate** (see above)
4. **Add to `apps/kustomization.yaml`**:
```yaml
resources:
  - my-service
```
5. **Add to homepage** (`apps/homepage/config/services.yaml`)
6. **Add to Gatus monitoring** (`apps/gatus/config.yaml`) for critical services
7. **Create PR and merge** — Flux deploys automatically

## Storage Considerations

### Local vs NFS Storage

**Local Storage (`storageClassName: local-path`)**:
- Use for: Services that need 24/7 uptime
- Examples: monitoring (Gatus), uptime checks
- Survives: the NAS being offline

**NFS Storage (NAS at 192.168.0.128 — NixOS + ZFS)**:
- Use for: Media services, large data
- Examples: Transmission, Sonarr, Radarr (media library)
- Limitation: Pod won't start if the NAS is offline
- Behavior: Pod waits patiently, resumes when storage returns

**GPU Node (`k3s-gpu`, 192.168.0.69)**:
- Use for: Services that need a CUDA GPU (Ollama, future TTS)
- Pin with `nodeSelector: node-role.kubernetes.io/gpu: "true"` + matching toleration
- GPU pods must set `runtimeClassName: nvidia` and request `nvidia.com/gpu: 1` in `resources.limits`
- PVCs on this node use `local-path` — see [docs/gpu-k3s.md](docs/gpu-k3s.md)

## Common Pitfalls

### 1. Applying Instead of Using GitOps
Use Pull Requests for all changes.

### 2. Per-Service TLS Certificates
Use `wildcard-home-tls` secret — never `cert-manager.io/cluster-issuer` annotation.

### 3. Wrong IngressClass
Use `traefik-traefik` (not `traefik`).

### 4. Forgetting to add to kustomization.yaml
Every service directory must be listed in `apps/kustomization.yaml`.
Infrastructure components must be listed in `clusters/my-cluster/infrastructure/kustomization.yaml`.

### 5. Ignoring CI Failures
Fix validation errors before merging — run `task validate` locally first.

## Secrets Management

**Never commit secrets to Git!**

Create secrets imperatively:
```bash
kubectl create secret generic my-secret \
  --from-literal=key=value \
  -n default
```

Reference in deployments:
```yaml
env:
  - name: API_KEY
    valueFrom:
      secretKeyRef:
        name: my-secret
        key: key
```

**GHCR pull auth** uses a static GitHub PAT stored as a SOPS-encrypted `dockerconfigjson` Secret at `apps/ghcr-pull-secret.enc.yaml`. Flux's `kustomize-controller` decrypts it at reconcile time using the age key in `flux-system/sops-age`. New apps in `default` namespace only need `imagePullSecrets: [{name: ghcr-pull}]` in their Deployment — no new resources required. Apps in a *different* namespace must create their own SOPS-encrypted `ghcr-pull` Secret targeting that namespace (copy `apps/ghcr-pull-secret.enc.yaml` and re-encrypt) — see `docs/ghcr-auth.md`. SOPS recipients are configured in `.sops.yaml` (any file ending `.enc.yaml` is encrypted to the cluster's age public key). To edit the encrypted Secret: `sops apps/ghcr-pull-secret.enc.yaml`. The `sops-age` Secret in `flux-system` is bootstrapped manually with `kubectl create secret` from the age private key — see `docs/ghcr-auth.md` for one-time setup. We previously used an ESO `GithubAccessToken` generator with a GitHub App PEM but it was too operationally fragile (#535/#536) — do not propose that approach again.

## Useful Commands

```bash
# Full local validation
task validate

# Check Flux status
flux get kustomizations
task status

# Force reconciliation
flux reconcile kustomization flux-system --with-source
task reconcile

# Watch pods
kubectl get pods -w

# View logs
kubectl logs -l app=my-service -f
task logs

# Restart deployment
kubectl rollout restart deployment/my-service
```

## Links

- [Flux CD Documentation](https://fluxcd.io/docs/)
- [cert-manager Documentation](https://cert-manager.io/docs/)

**Remember**: Always use Pull Requests. All changes must be reviewed and merged to main. Flux manages everything.
