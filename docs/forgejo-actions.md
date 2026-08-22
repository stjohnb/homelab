# Forgejo Actions and the In-Cluster Runner

## Architecture

`apps/forgejo-runner/` is one Deployment, one replica, two containers:

- `runner` (`code.forgejo.org/forgejo/runner:12.13.2`) — the Forgejo Actions runner daemon.
- `dind` (`docker.io/docker:29.6.2-dind`, privileged) — a Docker-in-Docker daemon that executes job containers.

The two containers talk over TLS on `localhost:2376`, with certs shared via an `emptyDir` mounted at `/certs` in both containers. Jobs run as Docker containers created by the dind daemon, fully isolated from the node's containerd.

### Why dind and not the node socket

`forgejo-runner` has no Kubernetes job execution backend. The only backends are `host` (jobs run directly inside the runner container, which is a bare Alpine image with no build toolchain) and `docker` (needs a Docker daemon). Mounting the node's containerd socket into the runner was rejected: a CI job with access to the node's containerd socket can see and control every workload on the cluster, not just its own job container. A dedicated dind sidecar keeps job execution fully isolated from the cluster.

## Node placement

The pod has no toleration for `node-role.kubernetes.io/gpu=true:NoSchedule` (the `ryzen` GPU node) or `node-role.kubernetes.io/storage=true:NoSchedule` (`k3s-nas`), and also carries an explicit `DoesNotExist` nodeAffinity for both labels as a belt-and-braces measure in case either taint is ever removed. In practice this means the pod lands on `k3s` (192.168.0.251), the only untainted node in the cluster.

Docker image layers and build cache live in a 15Gi-capped `emptyDir` on that node — they do not persist across pod restarts, and `containerd-gc` does not see or clean them (they belong to the dind daemon, not the node's containerd).

## Labels

Forgejo assigns a job to a runner only when every label listed in the workflow's `runs-on` is declared by that runner; the first matching label determines which container image the job runs in. The runner declares:

```
self-hosted, linux, docker, ubuntu-latest, ubuntu-22.04
```

all mapped to `docker://data.forgejo.org/oci/node:22-bookworm`. This means `runs-on: [self-hosted, linux]`, used by perudo's existing workflows, works unchanged. `data.forgejo.org/oci/node:22-bookworm` is a Forgejo-hosted mirror, chosen to avoid Docker Hub pull-rate limits.

## One-time registration procedure

Registration credentials are never stored in Git. `migrations/0017-forgejo-runner-secret.sh`
generates and registers them automatically as part of the repo's [secret migration
Job](apps-overview.md#secret-migration-jobs) — no manual step is required. It:

```bash
# 1. Generate a 40-character hex secret
SECRET=$(kubectl exec -n default "$FORGEJO_POD" -- \
  forgejo forgejo-cli actions generate-secret)

# 2. Register a GLOBAL runner (no --scope) and capture the UUID it prints
UUID=$(kubectl exec -n default "$FORGEJO_POD" -- \
  forgejo forgejo-cli actions register --name k3s-runner --secret "$SECRET")

# 3. Hand both to the runner
kubectl create secret generic forgejo-runner-secret -n default \
  --from-literal=uuid="$UUID" --from-literal=token="$SECRET"
```

skipping if `forgejo-runner-secret` already exists, and looking up the forgejo pod by label
(`app=forgejo`) since Deployment pod names change across rollouts. This requires the
`migration-runner` ServiceAccount to have `pods/exec` **and `get` on `pods`** in `default` —
`kubectl exec` GETs the pod first to resolve its default container. See the RBAC comment in
`migrations/rbac.yaml` for the accepted trade-off (exec can't be scoped to just the forgejo pod).

Registering globally (omitting `--scope`) makes the runner available to every org, not just perudo — fleet-infra's own CI is the eventual second consumer (see "Known gaps" below).

The first 16 characters of the secret are the runner identifier; the last 24 are the secret proper. Re-running `register` with the same first 16 characters and a new last 24 rotates the credential in place.

`register` writes directly to Forgejo's SQLite database while the server is running. If it reports `database is locked`, the migration Job's next reconcile (Flux forces a re-run every ~1m) simply retries.

UI fallback: `https://git.home.bstjohn.net/admin/actions/runners` → *Create new runner*, which yields the same UUID + token pair.

## Rotation

Rotation is still manual — the migration only handles first-time registration (mirroring how
`0011-headlamp-oidc-secret.sh` and its separate rekey script `0012-headlamp-oidc-rekey.sh` are
split, rather than making initial creation scripts also handle in-place rotation):

1. Re-run step 2 above (against the live forgejo pod) with a fresh secret.
2. `kubectl delete secret forgejo-runner-secret -n default`, then re-create it with the new UUID and token.
3. `kubectl rollout restart deployment/forgejo-runner`.

## Verification

```bash
kubectl logs -l app=forgejo-runner -c runner
```

should show a line like `runner: k3s-runner, ... declared successfully`. The runner should also appear **Online** at `https://git.home.bstjohn.net/admin/actions/runners`.

## Known gaps (deliberate)

1. **Actions cache disabled.** The runner's cache proxy binds in the pod network namespace, but job containers are created by the dind daemon on its own bridge network, so reaching the cache proxy would require guessing a gateway IP. No migrated workflow uses `actions/cache` yet. Re-enable later by setting `cache.enabled: true` and `cache.host` to the dind bridge gateway in `apps/forgejo-runner/config.yaml`.
2. **Persistent, not ephemeral, runner.** Forgejo was upgraded to 15.0.5 (issue #701, before this runner was deployed in #702), so ephemeral registration (`--ephemeral`) is available, but `migrations/0017-forgejo-runner-secret.sh` doesn't use it — the runner still registers persistently. Moving to ephemeral registration is unstarted follow-up work with no tracking issue yet.
3. **No Homepage or Gatus entry.** The runner has no HTTP surface — a Gatus check would need an authenticated Forgejo admin API call, which Gatus conditions can't express. A stuck runner shows up as jobs queueing forever in the Actions UI, not as a red check.
4. **fleet-infra's own CI still runs on the GitHub self-hosted runner.** Porting fleet-infra's CI to this runner is separate follow-up work, not part of this change.
