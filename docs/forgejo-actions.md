# Forgejo Actions and the In-Cluster Runner

**Depth:** **Reference**
**Read this when:** working on the in-cluster forgejo-runner, its Docker-in-Docker sidecar, or runner labels.
**Read instead:** [forgejo.md](forgejo.md) for Forgejo itself.

## Architecture

`apps/forgejo-runner/` is three Deployments, one replica each, two containers each:

- `forgejo-runner` (`k3s` node) — the original single runner from #702.
- `forgejo-runner-ryzen` (`ryzen` node) — added in #957 to converge Forgejo CI onto the same hardware as the GitHub Actions runner fleet.
- `forgejo-runner-nas` (`k3s-nas` node) — added in #957, same rationale.

Each Deployment carries the same two containers:

- `runner` (`code.forgejo.org/forgejo/runner:12.13.2`) — the Forgejo Actions runner daemon.
- `dind` (`docker.io/docker:29.6.2-dind`, privileged) — a Docker-in-Docker daemon that executes job containers.

The two containers talk over TLS on `localhost:2376`, with certs shared via an `emptyDir` mounted at `/certs` in both containers. That TLS listener is what the `dind` readiness probe checks; it is otherwise unused now — the `runner` container instead talks to `dind` over a second, unix-socket-only listener on an `emptyDir` shared at `/dind-sock`, because `DOCKER_CERT_PATH`/`DOCKER_TLS_VERIFY` were removed from the `runner` container's env (the moby client would otherwise attempt a TLS handshake over a unix socket). See [Docker in job containers](#docker-in-job-containers) below. Jobs run as Docker containers created by the dind daemon, fully isolated from the node's containerd.

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

The image is built by `St-John-Software/forgejo` on `git.home.bstjohn.net` from `runner-image/Dockerfile` (#1189), the same repo that builds the Forgejo server image. Routine rebuilds run on Forgejo Actions using the previous tag; from an empty registry or a dead forge use the BuildKit-Job break-glass in [registry.md](registry.md) "Bootstrap ordering".

The job image is built by `St-John-Software/forgejo`'s `.forgejo/workflows/build-runner-image.yml` and pushed to `registry.home.bstjohn.net/st-john-software/forgejo-runner-nix` — the self-hosted zot registry described in [registry.md](registry.md) — with a `YYYYMMDD-HHMM-<sha7>` tag plus `latest`. The LAN registry is the only push target — the GHCR push was removed in #975. It is `data.forgejo.org/oci/node:22-bookworm` plus a single-user nix installation copied from `nixos/nix:2.35.2`. Nix reaches `PATH` via `ENV` rather than a profile script, because `act_runner` runs `run:` steps in a non-login bash that never sources `/etc/profile.d`. `/etc/nix/nix.conf` sets `sandbox = false` and an empty `build-users-group` because job containers are unprivileged, with no `CAP_SYS_ADMIN` and no `nixbld` users.

The LAN registry requires authentication for reads — it has no anonymous policy. The mechanism is unchanged from when the image lived on GHCR; only the credential and the host differ. `act_runner` pulls the job image itself and forwards `X-Registry-Auth` to the dind daemon, so the sidecar needs no credentials of its own: `LoadDockerAuthConfig` in `act/container/docker/pull.go` (forgejo/runner v12.13.2) loads docker's `config.json` from the directory named by `DOCKER_CONFIG`, resolves the registry host from the image ref, and attaches the credential per pull, logging `using DockerAuthConfig authentication for docker pull` at info level when it fires. The credential is the `registry-pull` Secret minted by `migrations/0021-registry-credentials.sh` (the read-only `puller` identity — see [registry.md](registry.md)), projected into the `runner` container at `/docker-config/config.json` with `DOCKER_CONFIG=/docker-config` — see `deployment.yaml`. Manifests referencing this image must pin the immutable date-sha tag — never `latest`.

## Docker in job containers

`container.docker_host: unix:///dind-sock/docker.sock` in both `config.yaml` and `config-beefy.yaml` tells act_runner to bind-mount that path to `/var/run/docker.sock` inside every job container. A plain `docker` CLI in the job needs no env, no certs, no `sudo`, and no socket mount declared in the workflow — it just finds `/var/run/docker.sock` the way it would on a normal host.

TCP is not an option here: `configCheck` in `internal/app/cmd/daemon.go` (forgejo/runner v12.13.2) silently rewrites any non-`unix://`/non-`npipe://` `container.docker_host` scheme to `"-"` (no docker at all) before act_runner ever tries to use it. A `unix://` path is the only shape that survives. The dind server's TLS cert can't cover a TCP route either way — `dockerd-entrypoint.sh` computes its SANs from `ip -oneline address` before dockerd starts, so no bridge-gateway address is ever in the cert.

`container.valid_volumes` stays `[]`: `GetBindsAndMounts` (act/runner/run_context.go) auto-appends the resolved `docker_host` path to the job's allowed-volume list, so the socket needs no explicit whitelist entry, and nothing else should be mountable.

**Blast radius.** All three runners register globally — `migrations/0017-forgejo-runner-secret.sh`, `0022`, and `0023` omit `--scope` — so every repo on `git.home.bstjohn.net` that can schedule a job on this fleet gets Docker access to a privileged dind daemon. A job can start a `--privileged` sibling container via that daemon and escape to the node; with `runner.capacity: 2` per Deployment, two concurrent jobs on the same pod share one daemon and can inspect each other's containers and env. This is acceptable only because the forge is LAN-only and single-tenant; scope the runners per-org (`--scope`) if that ever changes. The job container itself stays unprivileged (`container.privileged: false`) — the risk is entirely in what it can ask the dind daemon to do on its behalf.

The job image (the tag pinned in `apps/forgejo-runner/config.yaml`) still ships no docker CLI. Consuming repos supply their own — bin-scraper's flake devShell provides `docker-client`.

**Verification runbook.** fleet-infra's own CI is still on GitHub Actions (see "Known gaps" below), so proving this needed a throwaway job on a repo that already runs on this fleet — e.g. a throwaway branch on perudo. bin-scraper's ported CI has since run for real (2026-09-08) and is the stronger proof below.

```yaml
# .forgejo/workflows/docker-smoke.yml on a throwaway branch — delete after.
on: [push]
jobs:
  smoke:
    runs-on: [self-hosted, linux]
    steps:
      - run: |
          ls -l /var/run/docker.sock
          curl -fsS --unix-socket /var/run/docker.sock http://localhost/version
```

`curl` is present in the `node:22-bookworm`-based job image, so this needs no extra toolchain. A full `docker version` / `docker build` proof came from a repo whose own flake supplies the `docker` CLI: bin-scraper's ported CI ran a real `docker build`/push through the dind socket on 2026-09-08.

Published container ports (e.g. `ports:` in a `docker-compose.yml` used by a job) land on the **`dind`** container's loopback, not the job container's — reach them via `docker exec`/`docker compose exec`, never `curl localhost:<port>` from a workflow step.

## Labels

Forgejo assigns a job to a runner only when every label listed in the workflow's `runs-on` is declared by that runner; the first matching label determines which container image the job runs in. All three runners declare:

```
self-hosted, linux, docker, ubuntu-latest, ubuntu-22.04
```

all mapped to `docker://registry.home.bstjohn.net/st-john-software/forgejo-runner-nix:<tag>` (the tag pinned in `apps/forgejo-runner/config.yaml`; see the [Job container image](#job-container-image) section). This means `runs-on: [self-hosted, linux]`, used by perudo's existing workflows, load-balances across the fleet with no workflow change.

`forgejo-runner-ryzen` and `forgejo-runner-nas` additionally declare `beefy` (from `apps/forgejo-runner/config-beefy.yaml`), for jobs that must never land on the small `k3s` box. **No workflow should adopt `beefy` yet** — both nodes are powered off much of the day, so a `beefy` job can queue indefinitely.

Fleet concurrency is 3 runners × `capacity: 2` = 6 concurrent jobs.

Bumping the tag requires a rollout restart of every Deployment carrying that label set — `kubectl rollout restart deployment/forgejo-runner deployment/forgejo-runner-ryzen deployment/forgejo-runner-nas` — `act_runner` reads `config.yml` only at daemon start.

`update-forgejo-runner-nix.yml`'s auto-merged PR does not restart anything — plain ConfigMaps, no content-hash suffix, no reloader in this cluster — so the restart stays manual and the PR body says so.

## Container MTU (#1194, #1288)

Each `dind` daemon runs with both `--mtu=1450` and
`--default-network-opt=bridge=com.docker.network.driver.mtu=1450`, matching the
pod's `eth0`. Flannel's VXLAN overlay costs 50 bytes, so pod interfaces are 1450
while the node's uplink is 1500. `dockerd`'s default is 1500 regardless.
`--mtu` reaches only `docker0` — plain `docker build` / `docker run` with no
`--network`. `--default-network-opt` is what reaches the per-job
`WORKFLOW-<hash>` bridge that `act_runner` creates for every job, because
`container.network` is `""` in `apps/forgejo-runner/config.yaml`. It needs
Docker 26+ (we run 29.x).

Left at 1500, containers advertise MSS 1460, the remote sends full-size frames,
and delivery depends on our ICMP `frag-needed` reaching the remote. When that
ICMP is filtered upstream the flow blackholes until PMTUD or RTO backoff shrinks
it. That was #1194: on the first bin-scraper Forgejo run (2026-09-08) `docker
build`'s `apt-get install` stalled 30 s at a time, four times, then failed with
`Connection timed out [IP: 151.101.2.132 80]`.

`--mtu` alone left every job container at 1500, which was #1288: perudo PR
309's `Infrastructure / plan` job failed `tofu init` three times (Forgejo tasks
68/72/76 on `forgejo-runner-957bc6798-75m9p`) with `net/http: request canceled
while waiting for connection (Client.Timeout exceeded while awaiting headers)`
fetching `terraform-provider-aws_5.100.0_SHA256SUMS` from `github.com`, while
the same job's AWS OIDC exchange and S3 backend init succeeded. The 2026-09-10
repro measured 1450 on `--network bridge` and 1500 on a fresh network, and
0.20 s vs a 20 s timeout fetching that URL.

It looked intermittent and `k3s`-specific because Linux caches a learned PMTU
per destination for 600 s: the first connection to a given IP stalls, the next
several are instant. A hand repro on the `k3s` dind fetching the same `.deb`
three times measured 21.03 s, 0.06 s, 0.04 s. The same reason `ryzen` looked
clean — its one passing run warmed the cache before anyone probed it. All three
runners carry the same setting; none of them was ever safe.

Not the cause, and already excluded before this: conntrack capacity
(2453/262144, nothing in dmesg), DNS (instant from job containers),
NetworkPolicies (none select these pods), and the node itself (`curl` of the
same URL from the k3s host: 30 ms x3 — the host path has no 1450 hop).

Runner capacity is deliberately unchanged at 2, and the `k3s` runner keeps its
`self-hosted`/`linux` labels. The stall reproduced with no concurrent job, so
concurrency was never implicated, and `k3s` is the only always-on runner —
de-pooling it would queue all Forgejo CI whenever `ryzen` and `k3s-nas` are off.

Verify after a rollout — all three commands must print 1450:

    kubectl exec deploy/forgejo-runner -c runner -- cat /sys/class/net/eth0/mtu
    kubectl exec deploy/forgejo-runner -c dind -- docker network inspect bridge \
      -f '{{index .Options "com.docker.network.driver.mtu"}}'
    # the one that actually matters — a FRESH user-defined network, which is
    # what act_runner gives every job:
    kubectl exec deploy/forgejo-runner -c dind -- sh -c \
      'docker network create mtucheck >/dev/null && \
       docker run --rm --network mtucheck alpine:3.22 cat /sys/class/net/eth0/mtu; \
       docker network rm mtucheck >/dev/null'

Repeat for `deploy/forgejo-runner-ryzen` and `deploy/forgejo-runner-nas`.

If a fetch still stalls, first confirm the fresh-network check above prints
1450. If it prints 1500, `--default-network-opt` did not take — check
`docker info` / the dockerd cmdline and the daemon version — and only then go
hunting on the node:

    # on 192.168.0.251, during a stall
    tcpdump -ni any 'icmp[icmptype] == 3 and icmp[icmpcode] == 4'
    conntrack -S | grep -E 'insert_failed|drop'
    sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.cni0.rp_filter

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

## Job logs and re-running jobs

Forgejo 15's API exposes no job-log or job-rerun endpoint for Actions. Logs live only on the `forgejo-data` PVC, inside the Forgejo pod (not the runner pod) at `/var/lib/gitea/actions_log/<owner>/<repo>/<hex-prefix>/<task-id>.log.zst` (zstd-compressed) — read them with `kubectl exec` into the `forgejo` pod, or via the web UI. The only way to re-run a job is to push a new commit; there is no API or CLI rerun trigger to script around.

## Known gaps (deliberate)

1. **Actions cache disabled.** The runner's cache proxy binds in the pod network namespace, but job containers are created by the dind daemon on its own bridge network, so reaching the cache proxy would require guessing a gateway IP. No migrated workflow uses `actions/cache` yet. Re-enable later by setting `cache.enabled: true` and `cache.host` to the dind bridge gateway in `apps/forgejo-runner/config.yaml`. Giving job containers Docker access (#1156, see [Docker in job containers](#docker-in-job-containers)) does not change this: the docker socket is a filesystem path bind-mounted into the job, not a network route, and the dind bridge gateway is still unreachable from it.
2. **Persistent, not ephemeral, runner.** Forgejo was upgraded to 15.0.5 (issue #701, before this runner was deployed in #702), so ephemeral registration (`--ephemeral`) is available, but `migrations/0017-forgejo-runner-secret.sh` doesn't use it — the runner still registers persistently. Moving to ephemeral registration is unstarted follow-up work with no tracking issue yet.
3. **No Homepage or Gatus entry.** None of the three runners has an HTTP surface — a Gatus check would need an authenticated Forgejo admin API call, which Gatus conditions can't express. A stuck runner shows up as jobs queueing forever in the Actions UI, not as a red check. The `ryzen` and `k3s-nas` runners are additionally offline whenever those nodes are powered off.
4. **fleet-infra's own CI still runs on the GitHub self-hosted runner.** Porting fleet-infra's CI to this runner is separate follow-up work, not part of this change.

## Rollback

Revert the PR. The Deployment change forces new pods on every affected node (`strategy: Recreate`), so no manual pod restart is needed either way.
