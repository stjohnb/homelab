# Shared Browser Service

**Depth:** **Reference**
**Read this when:** wiring a consumer to the shared headless Chromium service, debugging a queue-full/timeout error, or touching `apps/browser/`.

## Why one shared service

Claws spawns a `@playwright/mcp` process, and with it a full Chromium tree, inside whichever pod runs a `browser`-capability session or the shopping-sourcer job (a 4 GiB per-agent memory cap in `claude.ts` stops any one of those blowing its pod limit; observed peaks are 2–2.5 GiB for one Chromium tree, claws#2509). growth-engine's roadmap step 3 is "Playwright in a container", which would be a second, uncoordinated Chromium on node `k3s`. Rather than two independent browser processes fighting for memory on the same node, both consumers connect to one off-the-shelf `ghcr.io/browserless/chromium` deployment with a concurrency cap and a bounded wait queue.

fleet-infra builds no images (#1189 moved every Dockerfile to its own build repo) — this is why the service is the upstream browserless image rather than a wrapper. Its v2 licence is source-available and free for non-commercial use, which this homelab is. If that licence ever becomes a problem, the service can be swapped for another one behind the same WebSocket contract without either consumer changing.

## Layout

`apps/browser/`:

- `deployment.yaml` — one replica of `ghcr.io/browserless/chromium`, pinned to node `k3s` (the only always-on node; both consumers run there too), `priorityClassName: low-priority`, `strategy: Recreate`.
- `service.yaml` — ClusterIP `browser` on port 3000. No Ingress: nothing outside the cluster needs this.
- `networkpolicy.yaml` — ingress allow-list, see below.

The token is minted by `migrations/0036-browser-token.sh` into the `browser-token` Secret (key `token`), same shape as `migrations/0020-bin-scraper-session-secret.sh`.

## Endpoints

Browserless v2 refuses any connection without `TOKEN`, accepted either as `?token=` or `Authorization: Bearer`.

| Consumer | Env var | URL |
|----------|---------|-----|
| growth-engine (growth-engine#9) | `BROWSER_WS_ENDPOINT` | `ws://browser.default.svc.cluster.local:3000/chromium/playwright?token=$(BROWSER_TOKEN)` |
| Claws (claws#3102) | `CLAWS_BROWSER_CDP_ENDPOINT` | `ws://browser.default.svc.cluster.local:3000/chromium?token=$(BROWSER_TOKEN)` |

- growth-engine uses the Playwright-protocol route with `chromium.connect()`. That route rejects any client whose User-Agent is not Playwright ("Only playwright is allowed to work with this route") — `wscat` cannot test it.
- Claws uses the CDP route with `@playwright/mcp --cdp-endpoint` (`/` is an alias for `/chromium`). `wscat` can test this one.
- Claws forwards its `CLAWS_BROWSER_CDP_ENDPOINT` value into the session pods it launches, so `claws-sessions` needs no copy of the `browser-token` Secret.

### Assembling the URL

Each consumer declares a `BROWSER_TOKEN` env entry from `secretKeyRef: {name: browser-token, key: token}` **before** its endpoint env var — kubelet's `$(VAR)` expansion only sees env vars defined earlier in the same list.

The source of truth is `clusters/my-cluster/claws-staging/statefulset.yaml` for Claws (`optional: true`, because that Kustomization's `dependsOn` does not include `migrations`) and `apps/growth-engine/deployment.yaml` for growth-engine (no `optional`, since `apps` depends on `migrations`).

### Client compatibility

v2.56.7 is compatible with `playwright-core` 1.59–1.63. Recheck this range on every Renovate bump of the image tag.

### Persistent logins

Remote clients must keep per-account logins as Playwright `storageState`, not a user-data-dir — a remote browser (this service) has no access to a caller's local user-data-dir.

## The queue

Three env vars on the Deployment are the whole queue:

- `CONCURRENT=2` — sessions running at once.
- `QUEUED=10` — callers allowed to wait once `CONCURRENT` is full.
- `TIMEOUT=300000` — a session (queued or running) is killed after 5 minutes.

A third caller waits in the queue. An eleventh caller (past `CONCURRENT + QUEUED`) gets HTTP 429 immediately. Tune these together with the container's memory limit: two Chromium trees at ~2.5 GiB each, plus `/dev/shm`, can exceed the 4Gi limit and get the pod OOMKilled, dropping every session in flight. If OOMKills appear, raise the memory limit or lower `CONCURRENT` — don't just raise `CONCURRENT`.

## Health endpoints

`/active` (204 when under the concurrency cap) and `/pressure` (JSON with `running`/`queued` counts) both require `?token=`. The Deployment's readiness probe is an `exec` probe running `node` inside the container so the token never appears in `kubectl describe` output or process argv; liveness is a plain `tcpSocket` check on 3000.

## NetworkPolicy allow-list

`apps/browser/networkpolicy.yaml` default-denies ingress to the `browser` pod except from:

- pods labelled `app: claws-staging` or `app: growth-engine` in `default`
- pods labelled `claws-workload: session` in namespace `claws-sessions` (the per-session pods Claws launches)

A new consumer must be added to this allow-list or its connections silently time out (no RST, just a hang until the client's own timeout).

## No CPU limit

The container has a memory limit but no CPU limit — Chromium rendering is bursty, and CFS throttling of a page render mid-session is worse than temporary CPU contention with other `low-priority` pods on `k3s`. This departs from this repo's usual "CPU and memory limits everywhere" convention deliberately.

## Sandbox note

v2 removed browserless's `DEFAULT_LAUNCH_ARGS` env var. If a session fails at launch with a Chromium sandbox error, the fix is to pass `--no-sandbox` through the client's own Playwright launch args — not to add `SYS_ADMIN` or run the container privileged.

## Verification

After merge, in the cluster:

- `kubectl get secret browser-token` exists.
- `kubectl get pod -l app=browser -o wide` shows the pod Running and Ready on `k3s`.
- **Allowed path**: `kubectl exec claws-staging-0 -- node -e "fetch('http://browser:3000/active?token=<T>').then(r=>console.log(r.status))"` prints `204`.
- **Denied path**: `kubectl run np-test --rm -it --restart=Never --image=curlimages/curl:8.11.1 -- curl -m 5 http://browser.default.svc.cluster.local:3000/active` times out — it has no allowed label, so the NetworkPolicy drops it.
- **Queue**: from `claws-staging-0`, hold three CDP WebSocket connections open to `/chromium?token=…`. While they're open, `/pressure?token=…` reports `running: 2` and `queued: 1`, and the third connection only proceeds once one of the first two closes.
- `kubectl exec claws-staging-0 -- sh -c 'printenv CLAWS_BROWSER_CDP_ENDPOINT | sed "s/token=.*/token=<redacted>/"'` shows the `ws://browser.default.svc.cluster.local:3000/chromium?token=` prefix, and `printenv CLAWS_BROWSER_CDP_ENDPOINT | grep -c 'BROWSER_TOKEN'` prints `0` — no unexpanded `$(BROWSER_TOKEN)` literal.
