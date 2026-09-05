# Container Registry (zot)

**Reference.** Read this when working on the self-hosted zot registry. For GHCR pull auth (the other image source), see [ghcr-auth.md](ghcr-auth.md).

`registry.home.bstjohn.net` is a self-hosted OCI registry running [zot](https://zotregistry.dev/) in the cluster (`apps/registry/`). It holds the container images this organisation builds itself, moving them off GHCR.

## Path convention

```
registry.home.bstjohn.net/st-john-software/<name>:<tag>
```

The `st-john-software/` prefix is hard-coded lowercase in the build workflows — zot's repository names are case-sensitive and Docker rejects uppercase in a reference, so never interpolate the GitHub owner (`St-John-Software`) into a tag.

Both build workflows (`build-arpwatch.yml`, `build-forgejo-runner-nix.yml`) publish **only** here — the GHCR push was dropped once every GitHub Actions runner was on the LAN (#975). A registry push failure now fails the build loudly rather than being skipped. Image tags pushed to `ghcr.io/st-john-software/{arpwatch,forgejo-runner-nix}` before 2026-08-27 are retained, unmaintained, for emergency rollback only.

## Why zot

| Option | Why not |
|---|---|
| Forgejo packages | Ties image storage to the forge's SQLite DB and PVC; a Forgejo restore becomes an image restore too, and the runner would depend on the forge it pulls jobs from. |
| `registry:2` (distribution) | No retention policy, no GC scheduler, no web UI. Cleanup means a cron job driving the delete API by hand. |
| Harbor | Postgres + Redis + Trivy + six Deployments for a homelab that pushes two images. |
| **zot** | Single Go binary, no database, storage is a directory on a PVC, native tag-retention and scheduled GC, an optional web UI, and htpasswd + OIDC auth built in. |

## Configuration gotchas

**Never add `extensions.userprefs` to `config.json`** (`apps/registry/configmap.yaml`). zot v2.1.20's `ExtensionConfig` struct has no `UserPrefs` field, so its strict config decoder rejects the unknown key and crash-loops the pod (#970/#969). The key is also redundant even where it would be valid: zot enables userprefs implicitly whenever both the `search` and `ui` extensions are on.

## Auth model

There is **no anonymous access**. zot's config deliberately contains no `anonymousPolicy` key — its absence is what denies unauthenticated reads. Three identities:

| Identity | Where it lives | Used by |
|---|---|---|
| `ci` (read + write) | `registry-auth` Secret — an htpasswd line plus the plaintext `ci-username`/`ci-password` keys | GitHub Actions push (repo secrets `REGISTRY_USER`/`REGISTRY_PASSWORD`); Forgejo Actions push later |
| `puller` (read only) | `registry-auth`, plus a derived `registry-pull` dockerconfigjson Secret | kubelet `imagePullSecrets`; forgejo-runner's `DOCKER_CONFIG` |
| Authentik users in `infra` / `all-apps` | Authentik OIDC | the web UI (read) |

Both credentials are minted in-cluster by `migrations/0021-registry-credentials.sh` and are never committed. The migration hashes the passwords with SHA-512 crypt (`openssl passwd -6`, falling back to `mkpasswd` then `python3 -c 'crypt...'`) — zot accepts both bcrypt and SHA-crypt htpasswd hashes, and the `alpine/k8s` migration image ships no `htpasswd` binary. If all three hashers are missing the migration exits 1; mint the Secrets by hand with the two `kubectl create secret` commands from the script and the migration's guard will skip on the next reconcile.

The pod only ever mounts the `htpasswd` and `oidc.json` keys — the Deployment's `items:` list on the Secret volume is load-bearing, so the plaintext passwords never reach the container filesystem.

`build-arpwatch.yml`'s tag-computation step queries the tags API with the `ci` credential. It pipes a curl config file (`user = <user>:<pass>`) into `curl -K -` rather than using `curl -u user:pass`, which would put the plaintext password in the curl process's argv where any other job on the shared self-hosted runner could read it from `ps` or `/proc/<pid>/cmdline`. Pushes go through `docker/login-action` (`docker login --password-stdin`) and `ci.yml`'s `image-verify` job uses `crane auth login --password-stdin` for the same reason. Any new step that authenticates to the registry must use stdin — not argv, and not a credentials file on the runner's disk.

### Logging in from a workstation

```bash
kubectl get secret registry-auth -n default -o jsonpath='{.data.ci-password}' | base64 -d
docker login registry.home.bstjohn.net -u ci
```

### Web UI (Authentik OIDC)

zot handles OIDC itself, so the Ingress carries **no** `default-authentik-auth@kubernetescrd` middleware — a ForwardAuth redirect in front of `/v2/` would break `docker push` and `docker pull`.

- Authentik provider `registry-oidc`, application slug `registry`, bound to the `infra` and `all-apps` groups (read).
- Callback URI is `https://registry.home.bstjohn.net/zot/auth/callback/oidc`. zot derives it from `http.externalUrl` plus the provider key, and the only generic provider key it accepts is literally `oidc`.
- The issuer must be `https://auth.home.bstjohn.net/application/o/registry/` **with the trailing slash** — zot passes it verbatim to `zitadel/oidc`, which compares it byte-for-byte against the `issuer` in Authentik's discovery document.
- The `groups` scope mapping is required: zot's `accessControl` group policy reads the `groups` claim.

### Health checks

Two independent checks watch the registry, and both work around zot answering
`405` to `HEAD` and `401` to an unauthenticated `GET /v2/`:

- **Gatus** (`apps/gatus/config.yaml`) checks `http://registry.default.svc.cluster.local:5000/v2/`
  and asserts `[STATUS] == 401` — for an authenticated registry, a 401 *is* health.
- **Homepage** (`apps/homepage/config/services.yaml`) sets
  `siteMonitor: https://registry.home.bstjohn.net/v2/_zot/ext/mgmt`. Homepage
  issues a `HEAD` first and only falls back to `GET` when the status is `> 403`,
  so zot's 405 always costs a second request. The mgmt endpoint is served
  anonymously (zot's own UI calls it to enumerate login methods) and returns a
  genuine 200, so the dot stays green regardless of Homepage's status
  threshold. If `extensions.mgmt.enable` is ever turned off in
  `apps/registry/configmap.yaml`, this monitor goes red — change it to
  `/v2/` (401, still green) in the same PR.

## Retention and GC

`storage.retention` keeps, per repository: any tag matching `^latest$`, plus the 5 most recently pushed tags. Untagged manifests are swept (`deleteUntagged: true`), while `deleteReferrers: false` keeps buildx SBOM and provenance manifests attached to the tags that survive. GC runs every 24h with a 1h delay on newly-written blobs.

Consequence: rolling a deployment back more than 5 builds is not possible from the registry — re-run the image's build workflow to republish the tag. Do **not** raise the retention count; the `forgejo-runner-nix` image is roughly 2 GB per version.

If more than 5 builds land while a version-bump PR is still open, the tag that PR references can be swept before it merges, producing `ImagePullBackOff` on the next restart. The fix is to re-run the build.

## Storage and backups

`registry-data` is a 40Gi `local-path` PVC on the 24/7 `k3s` node (the Deployment's node affinity excludes the GPU and NAS nodes). `local-path` has no `allowVolumeExpansion`, so a resize is rejected by the API server and wedges the whole `apps` Kustomization — **never edit the PVC**.

Blobs are deliberately **not** backed up. Every image here is reproducible from `images/*/Dockerfile`; recovery from a lost PVC is re-running the build workflows.

## Credential rotation

Rotation is manual and not automatic:

1. `kubectl delete secret registry-auth registry-pull -n default`
2. Delete the `0021-registry-credentials` key from the `migration-state` ConfigMap so the migration re-runs, or wait for a rebuild. `0021` is deliberately not `# migration: repeatable` — re-running it after a manual deletion is the intended, explicit rotation trigger.
3. Read the new `ci-password` and update the `REGISTRY_PASSWORD` repository secret in `St-John-Software/fleet-infra` **by hand** — until you do, both build workflows fail at the login step, and build-arpwatch.yml also fails at its tag-computation step (HTTP 401 from the tags API).
4. Restart any pod holding a stale `registry-pull`-based pull (kubelet re-reads the Secret on the next pull).

## Bootstrap ordering

- zot pulls **its own** image from `ghcr.io/project-zot/...`, a public upstream image, so the registry never depends on itself.
- zot `log.Panic()`s if OIDC discovery fails at startup. **If Authentik is down when the registry pod starts, zot crashloops until Authentik answers.** Kubernetes backoff recovers it automatically; during the window, `arpwatch` and Forgejo job-container pulls fail. This is a real dependency — do not "fix" it by removing OIDC.
- Probes are `tcpSocket`, not `httpGet`: with auth on and no anonymous policy, `/v2/` answers 401, which an httpGet probe would score as a failure and crashloop the pod.
- On a cluster rebuild the PVC is empty. Both build workflows must be re-run before `arpwatch` and the Forgejo job containers can pull.

## Related

- [ghcr-auth.md](ghcr-auth.md) — the GHCR PAT + SOPS path the org images are migrating away from
- [forgejo-actions.md](forgejo-actions.md) — how the runner authenticates its job-container pulls
