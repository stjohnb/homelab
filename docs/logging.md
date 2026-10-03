# Logging Stack

**Depth:** **Reference**
**Read this when:** querying pod logs, or touching Loki/Promtail.
**Read instead:** [monitoring.md](monitoring.md) for Prometheus/Grafana metrics and alert rules.

Grafana Loki (single-binary, filesystem storage) plus a Promtail DaemonSet ship pod logs from every node to a central store, queryable in the existing Grafana at `grafana.home.bstjohn.net` alongside Prometheus metrics. This closes the gap where `kubectl logs`/Headlamp only read the kubelet's on-disk container logs, which vanish on pod deletion or reschedule — the worst case being NFS-dependent services (Immich, the servarr stack) that land on `k3s-nas`/`ryzen`, both of which power off daily (see [monitoring.md](monitoring.md) for the same node-flapping behaviour affecting `kube-prometheus-stack`).

## Components

Both HelmReleases live in `apps/monitoring/` in the `default` namespace, matching the rest of the monitoring stack (this repo has no dedicated `observability` namespace, unlike the sibling `production-infra` cluster this pattern was adapted from):

- `apps/monitoring/loki.yaml` — `loki` chart `6.16.0`, `deploymentMode: SingleBinary`.
- `apps/monitoring/promtail.yaml` — `promtail` chart `6.16.6`, DaemonSet on all three nodes.
- `apps/monitoring/loki-networkpolicy.yaml` — restricts Loki's ingress to itself (ring gossip), Grafana, Promtail, Gatus, and Prometheus.

The `grafana` HelmRepository they both source from lives in `clusters/my-cluster/infrastructure/grafana/` (`flux-system` namespace) rather than under `apps/` — `apps-kustomization.yaml` sets `targetNamespace: default`, which would place the HelmRepository in `default` where Flux's source-controller cannot find it (the same trap documented for `prometheus-community` in [monitoring.md](monitoring.md)).

Neither HelmRelease sets `spec.targetNamespace`; both use `metadata.namespace: default` directly (the same shape as `kube-prometheus-stack`), so the Helm release names are `loki` and `promtail` and the chart's fullname template collapses to a plain `loki` Service — hence `loki.default.svc.cluster.local:3100`, or just `loki:3100` from within `default`.

The chart's nginx `gateway` is disabled (`gateway.enabled: false`) — with a single Loki replica it only adds a pod, so Grafana and Promtail talk to `loki:3100` directly. `chunksCache`, `resultsCache`, `test`, `lokiCanary` and `read`/`write`/`backend` replicas are all disabled or zeroed too: they default to `true`/nonzero in chart 6.16.0, and `chunksCache` alone would deploy a memcached StatefulSet with an 8Gi allocation.

The Loki ruler and LogQL alerting rules (the `loki-rules/` layer in `production-infra`) are deliberately absent — this stack is for reading logs, not alerting on them. Log-based alerting can follow as a separate PR if it proves useful.

## Querying logs

Grafana hides **Explore** from users with the Viewer org role, so querying Loki requires Editor or Admin. The org role comes from Authentik group membership (`infra` or `authentik Admins` → Admin, everyone else → Viewer), synced on every proxy login — see `docs/authentik.md`, "Grafana Integration".

In Grafana Explore, select the **Loki** datasource (added via `additionalDataSources` in `apps/monitoring/kube-prometheus-stack.yaml`, `uid: loki`) and run a LogQL query, e.g.:

```
{namespace="default", app="immich"}
```

Promtail's default scrape config (untouched — see `apps/monitoring/promtail.yaml`) already emits `namespace`, `app`, `pod`, `container` and `node_name` labels, so filtering by any of those works without extra configuration. Because logs live in Loki rather than on the kubelet's disk, these lines are still queryable after the pod is deleted and rescheduled.

The datasource is wired through the chart's own `grafana.additionalDataSources` values key rather than a hand-edited ConfigMap, so it survives `kube-prometheus-stack` chart upgrades. The running Grafana pod's `grafana-sc-datasources` sidecar picks up the change without a pod restart.

Grafana 12's bundled Logs Drilldown app (`grafana-lokiexplore-app`) is an alternative to Explore for browsing logs without writing LogQL by hand; its Patterns tab depends on `loki.pattern_ingester.enabled: true` in `apps/monitoring/loki.yaml`.

## Log line format

In-house services emit one JSON object per line on stdout, per the structured logging contract owned by `St-John-Software/claws` [`docs/logging-conventions.md`](https://github.com/St-John-Software/claws/blob/main/docs/logging-conventions.md), added in [claws#3279](https://github.com/St-John-Software/claws/pull/3279).

The contract's fields:

- `time` — ISO 8601, UTC, millisecond precision.
- `level` — lowercase string, one of `debug info warn error`; never numeric.
- `msg` — short and constant; put ids and other variable data in fields, not in `msg`.
- `service` — matches the Kubernetes `app` label.
- `component` — subsystem or job within the service.
- `err` — an object `{type, message, stack}` when present.
- Correlation keys — `run_id`, `job`, `repo`, `issue`, `pr`, as applicable.
- HTTP access fields — `http.method`, `http.path`, `http.status`, `duration_ms`.

Keys are `snake_case`; duration fields end in `_ms`; no secrets in any field.

In-repo shell CronJobs — `config-backup` (`apps/config-backup/script-configmap.yaml`), `db-backup` (`apps/postgres/cronjob-db-backup.yaml`, `apps/immich/cronjob-db-backup.yaml`), `downloads-janitor` (`apps/servarr/downloads-janitor/script-configmap.yaml`), `containerd-gc` (`apps/containerd-gc/cronjob.yaml`), `admission-error-reaper` (`apps/admission-error-reaper/cronjob.yaml`) — may use logfmt (`level=info msg="..." key=value`) instead of JSON, since JSON is awkward to emit from shell. They mostly still emit bracketed `[name] ...` prefixes today; conversion to logfmt is tracked separately.

Nothing in this contract becomes a Loki label: Promtail's pipeline stays `- cri: {}`, and labels stay the low-cardinality set already documented above (`namespace`, `app`, `pod`, `container`, `node_name`). Fields are parsed at query time with `| json` or `| logfmt`, not promoted to labels at ingestion.

Query shapes this enables:

```
{app="garden"} | json | level="error"
{app="claws"} | json | component="ha-backup-monitor"
{namespace="default"} | logfmt | level="error"
{app="immich"} | detected_level="error"
```

The first two rely on services following the JSON contract above. The third covers the shell CronJobs once they emit logfmt. The last uses `detected_level`, which Loki's `discover_log_levels` attaches automatically from common log shapes — useful for third-party apps like Immich that only get Loki's automatic level detection, not the in-house contract.

## Retention and storage

- `limits_config.retention_period: 168h` (7 days), enforced by the compactor (`compactor.retention_enabled: true`) — matching `production-infra`'s `168h`.
- A 10Gi `local-path` PVC backs the single Loki pod. `local-path` has `ALLOWVOLUMEEXPANSION: false`, so this size cannot be grown later without deleting and recreating the PVC — which loses the entire log store. Retention is the control that keeps disk usage bounded; do not rely on manual pruning, and do not treat the PVC size as adjustable in place.

## Node pinning

Loki's `singleBinary.nodeSelector` pins it to `kubernetes.io/hostname: k3s`, the always-on control-plane node (same node Grafana and Prometheus already run on). This is mandatory, not an optimization: `local-path` is `WaitForFirstConsumer`, so a PVC pins its pod to whichever node first schedules it, and both other nodes (`k3s-nas`, `ryzen`) power off for most of the day. Landing Loki on either of them would make the log store unavailable whenever that node is off.

Promtail runs as a DaemonSet with `tolerations: [{operator: Exists, effect: NoSchedule}]` so it schedules onto all three nodes despite `k3s-nas`'s `node-role.kubernetes.io/storage=true:NoSchedule` and `ryzen`'s `node-role.kubernetes.io/gpu=true:NoSchedule` taints (the same approach `prometheus-node-exporter` uses). Its HelmRelease sets `disableWait: true` on install/upgrade/rollback for the same reason `kube-prometheus-stack` does — see [monitoring.md](monitoring.md#kube-prometheus-stack-helmrelease): Helm's `--wait` on a 3-node DaemonSet needs `numberReady >= 2`, which is unreachable whenever both flapping nodes are off. Loki itself keeps normal waiting since it is a single-replica StatefulSet on the always-on node.

## Access

Loki has no ingress and no `Certificate` — it stays ClusterIP-only, reached only through Grafana (as a datasource), Promtail (as a log push target), and Prometheus (scraping metrics), mirroring how Prometheus and Alertmanager stay internal. `apps/monitoring/loki-networkpolicy.yaml` restricts ingress on port 3100 to Grafana, Promtail, Gatus, and Prometheus pods, plus a portless rule allowing Loki's single-binary ring to gossip with itself over memberlist/gRPC.

## Health

Gatus probes `http://loki:3100/ready` (`apps/gatus/config.yaml`) — confirms the Loki pod is up and accepting traffic (Loki's HelmRelease does not set `disableWait`, so Flux already verifies the release installs cleanly).

Promtail's HelmRelease does set `disableWait: true` (see [Node pinning](#node-pinning) above), and the chart's Service is disabled by default (`service.enabled: false`), so there is no endpoint for Gatus to probe. Coverage instead comes from a Grafana alert rule in `apps/monitoring/kube-prometheus-stack.yaml` (`uid: promtail-daemonset-not-ready`) comparing `kube_daemonset_status_number_ready` for the `promtail` DaemonSet against a count of currently-Ready nodes — sourced from kube-state-metrics, so it needs no new Service or scrape target. The DaemonSet's own `kube_daemonset_status_desired_number_scheduled` is deliberately *not* used as the denominator: a powered-off `k3s-nas`/`ryzen` goes `NotReady` without being removed from the cluster, and `nodeShouldRunDaemonPod` decides desired count from node selectors and taint tolerations only — never readiness. Promtail's blanket toleration keeps both nodes in the desired count even while off, so desired would stay at 3 while ready drops to 1 and the rule would fire every night. Counting Ready nodes instead gives the correct "should be running" population and keeps the rule quiet whenever a node is off by design, firing only when promtail itself is unhealthy on nodes that are up. See [docs/monitoring.md](monitoring.md#cronjob-alerts) for the rule detail.

Both signals above are readiness checks, not delivery checks: a promtail pod stays Ready as soon as its HTTP server binds, even while pushing into a black hole (wrong client URL, Loki returning 429/400, a corrupt positions file), and Loki stays `/ready` while ingesting zero lines. The delivery check is a Grafana alert rule, `loki-no-lines-ingested` (`apps/monitoring/kube-prometheus-stack.yaml`), on `sum(increase(loki_distributor_lines_received_total[30m])) or on() vector(0)`, firing when it drops below `1`. This reads Loki's own distributor metric, so a single expression covers both halves of the pipeline — Promtail must have pushed lines for Loki to have received them — without any assumption about promtail's controller/DaemonSet internals; promtail's own `serviceMonitor.enabled` stays off since it would add nothing this doesn't already cover. Prometheus reaches this metric by scraping Loki through the chart's own ServiceMonitor (`monitoring.serviceMonitor.enabled: true` in `apps/monitoring/loki.yaml`) rather than a static `additionalScrapeConfigs` job; the `monitoring.serviceMonitor.labels.release: kube-prometheus-stack` label is load-bearing — kube-prometheus-stack's Prometheus CR only selects ServiceMonitors carrying that label, and without it the ServiceMonitor is created but silently never scraped.
