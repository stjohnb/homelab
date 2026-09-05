# Forgejo Actions and the In-Cluster Runner

**Reference.** Read this when working on the in-cluster forgejo-runner, its Docker-in-Docker sidecar, or runner labels. For Forgejo itself, see [forgejo.md](forgejo.md).

## Architecture

`apps/forgejo-runner/` is three Deployments, one replica each, two containers each:

- `forgejo-runner` (`k3s` node) — the original single runner from #702.
- `forgejo-runner-ryzen` (`ryzen` node) — added in #957 to converge Forgejo CI onto the same hardware as the GitHub Actions runner fleet.
- `forgejo-runner-nas` (`k3s-nas` node) — added in #957, same rationale.

Each Deployment carries the same two containers:

- `runner` (`code.forgejo.org/forgejo/runner:12.13.2`) — the Forgejo Actions runner daemon.
- `dind` (`docker.io/docker:29.6.2-dind`, privileged) — a Docker-in-Docker daemon that executes job containers.

The two containers talk over TLS on `localhost:2376`, with certs shared via an `emptyDir` mounted at `/certs` in both containers. Jobs run as Docker containers created by the dind daemon, fully isolated from the node's containerd.

### Why dind and not the node socket

`forgejo-runner` has no Kubernetes job execution backend. The only backends are `host` (jobs run directly inside the runner container, which is a bare Alpine image with no build toolchain) and `docker` (needs a Docker daemon). Mounting the node's containerd socket into the runner was rejected: a CI job with access to the node's containerd socket can see and control every workload on the cluster, not just its own job container. A dedicated dind sidecar keeps job execution fully isolated from the cluster.

## Node placement

The GitHub Actions runner fleet already runs on the Ryzen and NAS boxes (see [gpu-k3s.md](gpu-k3s.md) and [nas-k3s.md](nas-k3s.md)), so Forgejo CI converges on the same hardware rather than adding a fourth box. The dind-sidecar model keeps job containers off the host entirely — stronger isolation than the GitHub runners' run-directly-on-host model.

| Deployment | Node | Placement | Notes |
|---|---|---|---|
| `forgejo-runner` | `k3s` (192.168.0.251) | nodeAffinity `DoesNotExist` on both `node-role.kubernetes.io/gpu` and `node-role.kubernetes.io/storage`, no tolerations | The pod has no toleration for either taint, and also carries the explicit `DoesNotExist` nodeAffinity as a belt-and-braces measure in case either taint is ever removed. In practice this means the pod lands on `k3s`, the only untainted node in the cluster. |
| `forgejo-runner-ryzen` | `ryzen` (192.168.0.69) | `nodeSelector`/`toleration` on `node-role.kubernetes.io/gpu` | Deliberately **not** a GPU pod — no `runtimeClassName: nvidia`, no `nvidia.com/gpu` request. The card's 2 time-sliced units are fully allocated to Ollama and Whisper; requesting a third would leave this pod `Pending` forever, and the nvidia runtime buys a CI job nothing. |
| `forgejo-runner-nas` | `k3s-nas` (192.168.0.128) | `nodeSelector`/`toleration` on `node-role.kubernetes.io/storage` | Touches no NFS and mounts no PV — it is there for CPU/RAM/disk only. |

Each Deployment runs at `priorityClassName: low-priority`, so it is the preemptible tenant behind that node's primary workload (Ollama/Whisper on `ryzen`, servarr/Immich on `k3s-nas`, both at `priorityClassName: standard`).

Docker image layers and build cache live in a per-node, size-capped `emptyDir` — they do not persist across pod restarts, are never shared between nodes (the first job on any given node is always cold), and `containerd-gc` does not see or clean them (they belong to the dind daemon, not the node's containerd):

| Node | `docker-data` emptyDir | dind `ephemeral-storage` limit |
|---|---|---|
| `k3s` | 15Gi | 20Gi |
| `ryzen` | 30Gi | 40Gi |
| `k3s-nas` | 50Gi | 60Gi |

Both `ryzen` and `k3s-nas` are powered off much of the day, so their runners (and any `beefy`-labelled job — see [Labels](#labels)) are unavailable while they're down.

## Job container image

This build intentionally stays on GitHub Actions rather than moving to Forgejo Actions like the rest of CI: building it via Forgejo Actions would require a working forgejo-runner, and this image is what makes forgejo-runner work in the first place — a circular dependency. It stays on GitHub (or would need a docker-label job that doesn't depend on the nix image) until that circularity is resolved (#956).

The job image is built from `images/forgejo-runner-nix/` by `.github/workflows/build-forgejo-runner-nix.yml` and pushed to `registry.home.bstjohn.net/st-john-software/forgejo-runner-nix` — the self-hosted zot registry described in [registry.md](registry.md) — with a `YYYYMMDD-HHMM-<sha7>` tag plus `latest`. The LAN registry is the only push target — the GHCR push was removed in #975. It is `data.forgejo.org/oci/node:22-bookworm` plus a single-user nix installation copied from `nixos/nix:2.35.2`. Nix reaches `PATH` via `ENV` rather than a profile script, because `act_runner` runs `run:` steps in a non-login bash that never sources `/etc/profile.d`. `/etc/nix/nix.conf` sets `sandbox = false` and an empty `build-users-group` because job containers are unprivileged, with no `CAP_SYS_ADMIN` and no `nixbld` users.

The LAN registry requires authentication for reads — it has no anonymous policy. The mechanism is unchanged from when the image lived on GHCR; only the credential and the host differ. `act_runner` pulls the job image itself and forwards `X-Registry-Auth` to the dind daemon, so the sidecar needs no credentials of its own: `LoadDockerAuthConfig` in `act/container/docker/pull.go` (forgejo/runner v12.13.2) loads docker's `config.json` from the directory named by `DOCKER_CONFIG`, resolves the registry host from the image ref, and attaches the credential per pull, logging `using DockerAuthConfig authentication for docker pull` at info level when it fires. The credential is the `registry-pull` Secret minted by `migrations/0021-registry-credentials.sh` (the read-only `puller` identity — see [registry.md](registry.md)), projected into the `runner` container at `/docker-config/config.json` with `DOCKER_CONFIG=/docker-config` — see `deployment.yaml`. Manifests referencing this image must pin the immutable date-sha tag — never `latest`.

## Labels

Forgejo assigns a job to a runner only when every label listed in the workflow's `runs-on` is declared by that runner; the first matching label determines which container image the job runs in. All three runners declare:

```
self-hosted, linux, docker, ubuntu-latest, ubuntu-22.04
```

all mapped to `docker://registry.home.bstjohn.net/st-john-software/forgejo-runner-nix:20260827-1333-c982390` (see the [Job container image](#job-container-image) section). This means `runs-on: [self-hosted, linux]`, used by perudo's existing workflows, load-balances across the fleet with no workflow change.

`forgejo-runner-ryzen` and `forgejo-runner-nas` additionally declare `beefy` (from `apps/forgejo-runner/config-beefy.yaml`), for jobs that must never land on the small `k3s` box. **No workflow should adopt `beefy` yet** — both nodes are powered off much of the day, so a `beefy` job can queue indefinitely.

Fleet concurrency is 3 runners × `capacity: 2` = 6 concurrent jobs.

Bumping the tag requires a rollout restart of every Deployment carrying that label set — `kubectl rollout restart deployment/forgejo-runner deployment/forgejo-runner-ryzen deployment/forgejo-runner-nas` — `act_runner` reads `config.yml` only at daemon start.

## One-time registration procedure

Registration credentials are never stored in Git. `migrations/0017-forgejo-runner-secret.sh`
generates and registers them automatically as part of the repo's [secret migration
Job](apps-overview.md#secret-migration-jobs) — no manual step is required. It:

```bash
# Generate and register in one in-pod shell, then hand both values to the runner.
OUT=$(kubectl exec -n default "$FORGEJO_POD" -- sh -c '
  set -e
  S=$(forgejo forgejo-cli actions generate-secret)   # 40-char hex secret
  U=$(forgejo forgejo-cli actions register --name k3s-runner --secret "$S")
  printf "%s\n%s\n" "$S" "$U"                        # GLOBAL runner: no --scope
')
kubectl create secret generic forgejo-runner-secret -n default \
  --from-literal=uuid="$(printf '%s\n' "$OUT" | sed -n 2p)" \
  --from-literal=token="$(printf '%s\n' "$OUT" | sed -n 1p)"
```

skipping if `forgejo-runner-secret` already exists, and looking up the forgejo pod by label
(`app=forgejo`) since Deployment pod names change across rollouts. This requires the
`migration-runner` ServiceAccount to have `pods/exec` **and `get` on `pods`** in `default` —
`kubectl exec` GETs the pod first to resolve its default container. See the RBAC comment in
`migrations/rbac.yaml` for the accepted trade-off (exec can't be scoped to just the forgejo pod).

The token is generated and consumed entirely inside the pod on purpose: `kubectl exec`
encodes every argument after `--` as a `command=` query parameter, so a secret passed
as an argv is recorded verbatim in the apiserver's `requestURI` and captured by
Kubernetes audit logging at any audit level (#902). `scripts/check-migration-exec-secrets.sh`
enforces this in CI.

Registering globally (omitting `--scope`) makes the runner available to every org, not just perudo — fleet-infra's own CI is the eventual second consumer (see "Known gaps" below).

The first 16 characters of the secret are the runner identifier; the last 24 are the secret proper. Re-running `register` with the same first 16 characters and a new last 24 rotates the credential in place.

`register` writes directly to Forgejo's SQLite database while the server is running. If it reports `database is locked`, the migration Job's next reconcile (Flux forces a re-run every ~1m) simply retries.

UI fallback: `https://git.home.bstjohn.net/admin/actions/runners` → *Create new runner*, which yields the same UUID + token pair.

`migrations/0022-forgejo-runner-ryzen-secret.sh` and `migrations/0023-forgejo-runner-nas-secret.sh` mirror `0017` exactly, registering `ryzen-runner` and `nas-runner` with their own UUID+token pair in `forgejo-runner-ryzen-secret` / `forgejo-runner-nas-secret`. **Never share one registration UUID between daemons** — Forgejo's runner bookkeeping breaks if two pods present the same UUID, which is also why every one of these Deployments keeps `strategy: Recreate`.

## Rotation

Rotation is still manual — the migration only handles first-time registration (mirroring how
`0011-headlamp-oidc-secret.sh` and its separate rekey script `0012-headlamp-oidc-rekey.sh` are
split, rather than making initial creation scripts also handle in-place rotation). The procedure is per-runner; repeat against the relevant (secret, Deployment) pair:

| Runner | Secret | Deployment |
|---|---|---|
| `k3s` | `forgejo-runner-secret` | `forgejo-runner` |
| `ryzen` | `forgejo-runner-ryzen-secret` | `forgejo-runner-ryzen` |
| `k3s-nas` | `forgejo-runner-nas-secret` | `forgejo-runner-nas` |

1. Re-run step 2 above (against the live forgejo pod) with a fresh secret, using that runner's `--name`.
2. `kubectl delete secret <secret> -n default`, then re-create it with the new UUID and token.
3. `kubectl rollout restart deployment/<deployment>`.

## Verification

```bash
kubectl get pods -l component=forgejo-runner -o wide
```

should show three pods, one on each of `k3s`, `ryzen`, and `k3s-nas`. All three should appear **Online** at `https://git.home.bstjohn.net/admin/actions/runners`, with `beefy` shown against the `ryzen` and `k3s-nas` runners.

```bash
kubectl logs -l app=forgejo-runner -c runner
```

should show a line like `runner: k3s-runner, ... declared successfully` (substitute `app=forgejo-runner-ryzen`/`app=forgejo-runner-nas` and `ryzen-runner`/`nas-runner` for the other two).

To confirm private-image pull auth is active:

```bash
kubectl logs -l app=forgejo-runner -c runner | grep -i dockerauthconfig
```

The `using DockerAuthConfig authentication for docker pull` line only appears when a job actually triggers a pull — `container.force_pull: false` means once per dind lifetime.

## Known gaps (deliberate)

1. **Actions cache disabled.** The runner's cache proxy binds in the pod network namespace, but job containers are created by the dind daemon on its own bridge network, so reaching the cache proxy would require guessing a gateway IP. No migrated workflow uses `actions/cache` yet. Re-enable later by setting `cache.enabled: true` and `cache.host` to the dind bridge gateway in `apps/forgejo-runner/config.yaml`.
2. **Persistent, not ephemeral, runner.** Forgejo was upgraded to 15.0.5 (issue #701, before this runner was deployed in #702), so ephemeral registration (`--ephemeral`) is available, but `migrations/0017-forgejo-runner-secret.sh` doesn't use it — the runner still registers persistently. Moving to ephemeral registration is unstarted follow-up work with no tracking issue yet.
3. **No Homepage or Gatus entry.** None of the three runners has an HTTP surface — a Gatus check would need an authenticated Forgejo admin API call, which Gatus conditions can't express. A stuck runner shows up as jobs queueing forever in the Actions UI, not as a red check. The `ryzen` and `k3s-nas` runners are additionally offline whenever those nodes are powered off.
4. **fleet-infra's own CI still runs on the GitHub self-hosted runner.** Porting fleet-infra's CI to this runner is separate follow-up work, not part of this change.
