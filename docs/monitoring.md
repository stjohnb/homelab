# Monitoring Stack

The monitoring stack lives in `monitoring/` and provides metrics collection, visualization, and custom exporters for both Kubernetes and external infrastructure.

## Components

```
monitoring/
├── kustomization.yaml
├── kube-prometheus-stack.yaml           # HelmRelease with all values
├── grafana-networkpolicy.yaml           # Restricts Grafana port 3000 to traefik namespace + gatus + prometheus
├── prometheus-networkpolicy.yaml        # Restricts Prometheus port 9090 to traefik namespace + grafana + gatus
├── grafana-github-alerts-networkpolicy.yaml  # Restricts webhook port 8080 to Grafana pods only
├── pve-exporter/
│   ├── deployment.yaml                  # Proxmox metrics exporter
│   └── service.yaml
├── grafana-github-alerts/
│   ├── deployment.yaml                  # Python webhook receiver (port 8080)
│   ├── service.yaml
│   ├── configmap.yaml                   # server.py script (stdlib only)
│   ├── shared-secret.enc.yaml           # SOPS-encrypted shared secret (auth token)
│   └── kustomization.yaml
└── dashboards/
    ├── pvc-capacity-dashboard.yaml      # PVC usage table + local-path bar gauge
    ├── proxmox-temperature-dashboard.yaml  # Proxmox host CPU/hwmon temperatures
    └── authentik-dashboard.yaml         # Auth latency, throughput, failures, flow/worker metrics
```

## kube-prometheus-stack (HelmRelease)

Deployed via Flux HelmRelease from `prometheus-community/kube-prometheus-stack` chart version `72.9.1` (exact pin). The chart is pinned to an exact version — not a range — to prevent surprise upgrades that can trigger failed reconciles and unreviewed rollbacks. Renovate opens PRs for version bumps going forward. The HelmRepository source lives in `clusters/my-cluster/infrastructure/prometheus-community/` (flux-system namespace) — it was moved there from `apps/monitoring/` because `apps-kustomization.yaml` sets `targetNamespace: default`, which would have placed it in `default` where Flux's source controller cannot find it. The HelmRelease itself is in the `default` namespace. See [infrastructure-overview.md](infrastructure-overview.md#helmrepository-namespace-requirement) for the full explanation.

**Remediation**: The HelmRelease has `install.remediation.retries: 3` and `upgrade.remediation.retries: 3`. This is important because the Grafana subchart passes contact point values through Helm's `tpl` function — any chart upgrade that introduces template-processing changes can leave the HelmRelease in `UpgradeFailed` state. With remediation configured, Flux retries automatically rather than staying stuck until manual intervention.

**Timeouts**: `upgrade.timeout: 20m` and `rollback.timeout: 20m`. Grafana's `download-dashboards` init container (fetches from grafana.com) plus database migrations and alerting provisioning consistently exceed the Flux default of 5 minutes on this cluster. The rollback timeout matches the upgrade timeout. Note that a matching timeout never rescued a degraded-cluster rollback — see **No Helm wait** below. Only `upgrade.timeout` is set; `install.timeout` is left unset (Flux default 5m) because fresh installs use a different code path where the init container is less of a concern.

**No Helm wait (`disableWait: true` on install, upgrade and rollback)**: Helm's `--wait` gates release success on every resource in the chart reaching readiness, including the `prometheus-node-exporter` DaemonSet. Helm's DaemonSet check requires `numberReady >= desiredNumberScheduled - maxUnavailable`, which here is `3 - 1 = 2`. `ryzen` (GPU worker) and `k3s-nas` (storage worker) are powered off for most of the day, and the node-lifecycle controller marks their node-exporter pods `Ready=False` while the node is `NotReady`. With one worker down the check still passes (`numberReady: 2`); with **both** down it reports `numberReady: 1` and can never pass — so any values change or Renovate chart bump landing in that window blocked for the full 20-minute timeout, failed with `context deadline exceeded`, then rolled back and blocked *again* on the same DaemonSet, repeatedly. Because a rollback renders the previous known-good manifests, its failing too proves the wait — not the chart values — is the blocker. Confirmed on 2026-08-21: upgrades v119/v120 at 00:56Z/01:02Z succeeded while only `ryzen` was offline; every attempt after `k3s-nas` went `NotReady` at 02:03:54Z failed. That intermittency is why the `[k3s] Flux HelmRelease NotReady: default/kube-prometheus-stack` issue series (#336, #341, #348, #491, #496, #577, #584, #878) recurred for months without diagnosis. Note that `kubectl get pods` prints `1/1` for those pods — that is *container* readiness; the DaemonSet counts the pod `Ready` **condition**. With `disableWait: true` the release is applied and reported succeeded as soon as the manifests land; the `timeout: 20m` values are kept because Helm still waits on chart hooks such as the `admission-create` webhook-certgen Job. The trade-off is that Flux no longer auto-detects or auto-rolls-back a functionally broken upgrade, and the `slack-errors` Flux alert in `clusters/my-cluster/flux-system/notifications.yaml` will no longer fire for one — that job now belongs to the Gatus checks on `kube-prometheus-stack-grafana:80/api/health` and `kube-prometheus-stack-prometheus:9090/-/healthy` in `apps/gatus/config.yaml`. Note also that a stuck rollback silently reverts recently merged values: during the #878 window the CoreDNS alert rules merged in #876 were rolled back out of the live `kube-prometheus-stack-grafana` ConfigMap while Git still showed them present (they were reinstated by the v120 upgrade).

**Helm `tpl` / Grafana template incompatibility**: The Grafana subchart (`_config.tpl`) runs Helm's `tpl` function over the `alerting.contactpoints.yaml` values block. This causes any `{{ }}` expressions in contact point `settings` (title, text, message, etc.) to be interpreted as Go/Helm templates. Grafana uses its own notification template functions (e.g., `toUpper`, `range .Alerts`) that are not registered in Helm's Sprig FuncMap — so including them in `settings` values causes a render failure at `helm upgrade` time, not at runtime. **Do not add custom `title`, `text`, or other template expressions in contact point settings.** Use plain strings or Grafana's `$__env{VAR}` syntax (which passes through `tpl` safely since it contains no `{{ }}`). If rich notification formatting is needed, use `alerting.notificationTemplates` with a named template reference in the contact point settings (the template body can use Grafana functions; only the reference string passes through `tpl`). Alert rule `annotations` (in `rules.yaml`) are processed by Prometheus, not Helm, so they are not affected — but if they do pass through `tpl` in a future chart version, use the Go escape syntax `{{ "{{" }}` to output a literal `{{`.

### Grafana

| Setting | Value |
|---------|-------|
| Domain | grafana.home.bstjohn.net |
| Port | 8080 |
| Storage | 5 GB, local-path |
| Auth | Secret `grafana-admin-secret` (keys: `admin-user`, `admin-password`) |
| Init chown | Disabled (fails on existing PVCs with subdirectories) |

**SSO**: Grafana uses Authentik's ForwardAuth middleware on its ingress plus `auth.proxy` for header-based session mapping. `auto_sign_up: false` — only pre-existing Grafana users can log in via proxy auth. A NetworkPolicy (`grafana-networkpolicy.yaml`) restricts Grafana's ingress on port 3000 to pods in the `traefik` namespace, the Gatus health check, and Prometheus (self-monitoring scrape), preventing in-cluster header spoofing from any other pod. `whitelist: 10.42.0.0/16` is a secondary safeguard. Local admin login remains enabled as a fallback. See [authentik.md](authentik.md).

**Dashboards**:
- **Proxmox** — Grafana.com dashboard ID 10347 (revision 5), auto-provisioned
- **PVC Capacity** — Custom ConfigMap; table of all PVC usage + bar gauge for local-path PVCs
- Sidecar watches for ConfigMaps labeled `grafana_dashboard` and injects them automatically

**Dashboard provider config**: Custom dashboards folder at `/var/lib/grafana/dashboards/custom`, editable, deletion allowed.

### Prometheus

| Setting | Value |
|---------|-------|
| Domain | prometheus.home.bstjohn.net |
| Retention | 30 days |
| Storage | 20 GB, local-path |

**SSO**: Prometheus uses Authentik's ForwardAuth middleware on its ingress — no application-level auth integration needed. ForwardAuth only covers the Traefik path, so a NetworkPolicy (`prometheus-networkpolicy.yaml`) also restricts Prometheus's ingress on port 9090 to the `traefik` namespace, the Grafana datasource, and Gatus; a separate portless rule allows Prometheus to keep scraping itself (including the config-reloader sidecar on 8080). Without it, any in-cluster pod could query cluster metrics directly on the ClusterIP.

**Built-in exporters**:
- Node Exporter — enabled (k3s node metrics)
- kube-state-metrics — enabled (Kubernetes object metrics)

**Disabled components** (k3s bundles these internally):
- kubeEtcd, kubeControllerManager, kubeScheduler, kubeProxy

**Alertmanager**: Disabled. Alerting is handled by Gatus + Slack instead.

### Scrape Configurations

Six additional scrape configs defined in `additionalScrapeConfigs`:

#### pve-exporter (Proxmox)

```yaml
job_name: pve-exporter
metrics_path: /pve
params:
  module: [default]
  target: ["192.168.0.200"]       # Proxmox host
static_configs:
  - targets: ["pve-exporter:9221"]
```

The exporter runs as a separate deployment and scrapes Proxmox API at 192.168.0.200.

#### cert-manager

```yaml
job_name: cert-manager
static_configs:
  - targets: ["cert-manager.cert-manager.svc.cluster.local:9402"]
```

Scrapes cert-manager's built-in Prometheus metrics endpoint. Key metrics include `certmanager_certificate_expiration_timestamp_seconds` (certificate expiry tracking), `certmanager_certificate_ready_status` (renewal health), and `certmanager_http_acme_client_request_duration_seconds` (ACME challenge latency). Uses FQDN because cert-manager runs in the `cert-manager` namespace while Prometheus runs in `default`. Since all services share a single wildcard certificate, this provides early warning when renewal fails.

#### authentik (SSO metrics)

```yaml
job_name: authentik
metrics_path: /metrics
static_configs:
  - targets: ["authentik-server:9300"]
```

Authentik exposes built-in Prometheus metrics on port 9300. Provides auth request latency,
failed authentication counts, active sessions, and outbound provider health. No separate
exporter needed — the Authentik server has a native metrics endpoint.

#### authentik-worker

```yaml
job_name: authentik-worker
metrics_path: /metrics
static_configs:
  - targets: ["authentik-worker:9300"]
```

Scrapes metrics from the Authentik async worker process. Provides background job queue depth,
task execution latency, and worker health.

#### gatus

```yaml
job_name: gatus
metrics_path: /metrics
static_configs:
  - targets: ["gatus.default.svc.cluster.local:8080"]
```

Scrapes Gatus uptime monitoring metrics. Provides endpoint response times, success/failure
rates, and alert status. Uses FQDN since Gatus runs in the `default` namespace.

#### proxmox-node-exporter (Proxmox host hardware)

```yaml
job_name: proxmox-node-exporter
static_configs:
  - targets: ["192.168.0.200:9100"]
    labels:
      instance: proxmox
```

Scrapes `prometheus-node-exporter` running directly on the Proxmox host. Provides hardware
temperature via `node_hwmon_temp_celsius`. The `instance: proxmox` label is hardcoded so
dashboards and alerts can use a stable name rather than the IP. Requires manual installation
on the Proxmox host — see "Proxmox Node Exporter (host-side setup)" below.

## PVE Exporter

**Image**: `prompve/prometheus-pve-exporter:3.8.1`
**Port**: 9221
**Resources**: 50m CPU, 64-128 MB memory
**Probes**: liveness + readiness (httpGet `/` port 9221)

Scrapes metrics from the Proxmox VE API. Environment variables:

| Var | Source |
|-----|--------|
| `PVE_USER` | Secret `pve-exporter-secret` |
| `PVE_PASSWORD` | Secret `pve-exporter-secret` |
| `PVE_VERIFY_SSL` | `false` (self-signed cert on Proxmox) |

The Prometheus scrape config passes `target: 192.168.0.200` as a parameter — the exporter connects to that Proxmox host.

### Proxmox Node Exporter (host-side setup)

`prompve/prometheus-pve-exporter` does not expose hardware temperature — the Proxmox API has no thermal endpoint. To monitor CPU temperature, install `prometheus-node-exporter` and `lm-sensors` directly on the Proxmox host. This exposes `node_hwmon_temp_celsius` metrics that Prometheus scrapes from inside the cluster.

**Manual steps on the Proxmox host (run as root):**

```bash
apt update
apt install -y prometheus-node-exporter lm-sensors
sensors-detect --auto
systemctl enable --now prometheus-node-exporter
# Verify: curl -s localhost:9100/metrics | grep node_hwmon_temp_celsius
```

**Firewall**: Proxmox's `pve-firewall` (if enabled) must allow TCP 9100 from the k3s pod CIDR `10.42.0.0/16`. If `pve-firewall` is disabled (the default), no action is required.

**Troubleshooting**: If `node_hwmon_temp_celsius` returns no series after installation, the kernel hwmon module may not be loaded. Check what is available with `cat /sys/class/hwmon/hwmon*/name` and load the appropriate module manually (`modprobe coretemp` for Intel, `modprobe k10temp` for AMD), then add it to `/etc/modules` for persistence and restart node_exporter.

## Grafana Alerting

Grafana Unified Alerting (enabled by default in Grafana 9+) is used for alert rules. Alertmanager remains disabled — alerts route via Grafana directly to Slack.

**No AWTRIX, no watchdog pods.** When the #842 CoreDNS SERVFAIL incident (35h of undetected cluster-wide DNS failure) was scoped, @stjohnb explicitly rejected both a new watchdog pod ("I'm not sure about putting a new watchdog pod in") and routing alerts through the AWTRIX pixel-display proxy ("Do not use awtrix for alerts"), asking instead whether Prometheus/Grafana could cover it. New detection for cluster-health gaps should extend the existing Grafana alert rules and Slack/GitHub-Issues channels — the same channels every other alert in this repo uses — not a bespoke pod or a new notification target.

### CronJob Alerts

Alert rules monitor CronJob health for critical scheduled jobs:

| Rule | Condition | Threshold | Severity |
|------|-----------|-----------|----------|
| Immich DB Backup Job Failed | `kube_job_status_failed > 0` with `reason!~"DeadlineExceeded|PodFailurePolicy"` | 5m pending | critical |
| Immich Database Is Empty | `kube_job_status_failed > 0` with `reason="PodFailurePolicy"` (backup exit 3, asset/user rows are 0) | 30m pending | warning |
| Immich DB Backup Running Too Long | active job running > 10 min AND k3s-nas Ready | 0s pending | warning |
| Containerd GC Job Failed | `kube_job_status_failed > 0` for `containerd-gc-[0-9]+` (main node only) | 1m pending | warning |
| Containerd GC Storage Job Failed | `kube_job_status_failed > 0` AND k3s-nas continuously Ready for 26h, for `containerd-gc-storage-[0-9]+` | 5m pending | warning |
| Immich DB Backup Schedule Missed | No new job in >12h (2x interval) (or, if never scheduled, CronJob created that long ago) | 5m pending | critical |
| Containerd GC Schedule Missed | No new job in >2 days (2x daily interval) (or, if never scheduled, CronJob created that long ago) | 5m pending | warning |
| Forgejo Backup Job Failed | `kube_job_status_failed > 0` for `forgejo-backup-[0-9]+` (no node guard) | 5m pending | critical |
| Forgejo Offsite Backup Job Stale | `forgejo-backup-offsite` last success (or CronJob creation, if never successful) >14 days ago | 30m pending | warning |
| Forgejo Backup Job Stale | `forgejo-backup` last success (or CronJob creation, if never successful) >2 days ago | 30m pending | critical |
| Config Backup Job Failed | `kube_job_status_failed > 0` AND k3s-nas continuously Ready for 26h | 5m pending | warning |
| Config Backup (Players) Job Failed | `kube_job_status_failed > 0` for `config-backup-players.*` with `reason!="DeadlineExceeded"` | 5m pending | warning |
| Config Backup Schedule Missed | No new job in >2 days (2x daily interval) (or, if never scheduled, CronJob created that long ago) | 5m pending | warning |
| Config Backup Job Stale | `config-backup` last success (or CronJob creation, if never successful) >14 days ago | 30m pending | warning |
| Config Backup (Players) Job Stale | `config-backup-players` last success (or CronJob creation, if never successful) >14 days ago | 30m pending | warning |
| Migration Runner Job Failed | `max_over_time(kube_job_status_failed{job_name="migration-runner"}[20m]) > 0` | 5m pending | warning |
| Kube State Metrics Down | `absent(up{job="kube-state-metrics"} == 1)` | 15m pending | warning |
| CoreDNS SERVFAIL Rate High | >5% of CoreDNS responses are SERVFAIL | 10m pending | critical |
| CoreDNS Upstream Unreachable | increase(coredns_forward_healthcheck_broken_total[10m]) > 0 | 5m pending | critical |

The containerd-gc alerts are split into two separate rules: `containerd-gc-job-failed` watches only the main-node job (`containerd-gc-[0-9]+`, runs at 04:00) and always alerts on failure regardless of NAS state. `containerd-gc-storage-job-failed` watches only the k3s-nas job (`containerd-gc-storage-[0-9]+`, runs at 04:30) and uses `min_over_time((max by (node) (kube_node_status_condition{node="k3s-nas", condition="Ready", status="true"}))[26h:1m]) == 1` — the node must have been continuously Ready for 26 hours before a failed job fires an alert. This 26-hour window ensures at least one full scheduled run has elapsed while the node was healthy; if that run failed, the alert fires. If k3s-nas was offline for days and just came back online, any stale failed jobs from that downtime are suppressed until the node has been up long enough for a fresh run to succeed (or fail genuinely). The `for: 5m` debounce prevents flapping when many series flip simultaneously on node-Ready transitions. This split exists because the main-node GC has no NAS dependency, so its failures are always genuine; the storage-node GC depends on k3s-nas being alive to schedule the pod.

The Immich backup alerts are split by Job failure reason for the same reason the containerd-gc alerts are split by node: an expected, known failure mode must not share a rule with a genuine one. `immich-db-backup-job-failed` excludes `reason="PodFailurePolicy"` (the empty-database refusal) alongside `reason="DeadlineExceeded"` (the NFS-Pending case), while `immich-db-empty` watches `reason="PodFailurePolicy"` exclusively.

`config-backup-job-failed` reuses the identical 26-hour `k3s-nas`-Ready guard for the same reason: the config backup mounts the NFS media share to write its archives, so every run while the NAS is powered off stalls on the mount and records a failure that is expected rather than actionable. Because the NAS powers off nightly at 03:03 with no scheduled wake, that guard is close to permanently false — it cannot itself confirm the backup is alive, which is how six days of zero successful `config-backup` runs went unnoticed after its creation on 2026-08-07. `config-backup-job-stale` (14 days, `kube_cronjob_status_last_successful_time`) is what actually proves that backup alive. See [docs/config-backups.md](config-backups.md).

`migration-runner-job-failed` is the only rule in this group watching a plain Job rather than a CronJob-generated one, so its Job name is fixed (`migration-runner`) and it omits the `topk(1, kube_job_status_start_time...)` newest-job selector the others use. It needs `max_over_time(...[20m])` instead: `ttlSecondsAfterFinished: 600` deletes the finished Job and the `migrations` Kustomization re-applies it within its 1-minute interval, so the metric series vanishes for a minute or two every ~11 minutes and a bare `> 0` rule would flap fire/resolve indefinitely. It excludes no `reason` — unlike the NFS-dependent backup jobs, `DeadlineExceeded` here means a migration script hung past `activeDeadlineSeconds: 600` and is actionable.

`config-backup-players-job-failed` (watching `config-backup-players.*`) takes the same approach as the Immich rule below rather than the 26-hour guard above: it filters on `reason!="DeadlineExceeded"`. That CronJob runs on the always-on `k3s` node, but its destination is the hard-mounted `media-pvc`, so a night the NAS is asleep produces a Job failure identical in shape to Immich's NFS-Pending case. The 26-hour Ready gate was rejected here because the NAS powers off at 03:03 nightly and would essentially never satisfy a 26-hour continuous-Ready requirement. See [docs/config-backups.md](config-backups.md#alerting).

These alerts use `kube-state-metrics` (`kube_job_status_*`, `kube_cronjob_status_*`) and `topk(1, kube_job_status_start_time)` to only evaluate the most recent job per CronJob.

**`noDataState` semantics**: All CronJob rules now use `noDataState: OK`. Schedule-missed rules previously used `noDataState: NoData` on the theory that an absent series was itself evidence of a missed schedule, but that made them fire on any scrape gap: when the `k3s` node's container runtime restarted at 2026-08-10T16:52:50Z, taking down Prometheus and kube-state-metrics together, all three fired `DatasourceNoData` 30 seconds later and filed issues #783/#784/#785 (the `for: 5m` pending period is not applied to NoData transitions). The "never scheduled" case they were protecting is now encoded in the query itself via an `or (time() - max by (cronjob) (kube_cronjob_created{...}))` fallback — kube-state-metrics publishes no `kube_cronjob_status_last_schedule_time` series until `.status.lastScheduleTime` is set (issues #708, #772). Total loss of kube-state-metrics is covered explicitly by `kube-state-metrics-down`, which has a real 15-minute pending period. The `proxmox-cpu-temp-high` rule keeps `noDataState: NoData` — see the Proxmox section.

**No node-readiness guard on the Immich backup alert**: The `immich-db-backup-job-failed` PromQL expression filters on `reason!="DeadlineExceeded"` rather than gating on k3s-nas readiness. When the NAS is offline, the backup pod stalls in `ContainerCreating` waiting for the NFS PVC mount and is eventually killed by `activeDeadlineSeconds: 1800`, which kube-state-metrics reports as `kube_job_status_failed{reason="DeadlineExceeded"}` — that series is excluded, so the expected NFS-Pending case does not fire. Any other failure (Postgres unreachable, a rejected dump) surfaces a `kube_job_status_failed` series with a different `reason` (or, briefly, no `reason` label at all, which also satisfies `!=`) and fires regardless of NAS uptime. The rule previously gated on `min_over_time(kube_node_status_condition{node="k3s-nas", condition="Ready", status="true"}[7h]) == 1`, but because the NAS is deliberately powered off most of the time, that guard suppressed genuine backup failures along with the expected NFS-Pending ones — this is how three months of empty-database backups reported success without ever alerting (issue #698). `topk(1, kube_job_status_start_time)` scopes the alert to the most recent scheduled run, so once a later run succeeds the series drops out and the alert self-resolves under `noDataState: OK`. Severity is `critical`.

**No node guard on the Forgejo backup alert**: `forgejo-backup-job-failed` has never carried a `k3s-nas` readiness guard, unlike the historical Immich rule (see above — the Immich guard has since been removed in favor of `reason!="DeadlineExceeded"`). The Forgejo backup is split into two stages to avoid the NFS coupling that motivated Immich's guard in the first place: stage 1 (`forgejo-backup`, 02:30) dumps to a `local-path` PVC on the 24/7 node and mounts no NFS, so it has no expected-failure mode to suppress and any failure is real. The off-node copy is stage 2 (`forgejo-backup-offsite`, 03:00), whose nightly failures while the NAS is off are expected and are not alerted on at all — only 14 days of consecutive failure raises the warning-level `forgejo-offsite-backup-job-stale`. See [docs/forgejo-backups.md](forgejo-backups.md). The staleness rule anchors to `kube_cronjob_created` when no success has been recorded, because kube-state-metrics publishes no `kube_cronjob_status_last_successful_time` series before the first success — see [docs/forgejo-backups.md](forgejo-backups.md). `forgejo-backup-job-stale` applies the same creation-timestamp anchoring at a 2-day threshold and is the persistent counterpart to the edge-triggered, `topk(1)`-scoped `forgejo-backup-job-failed`, covering the case where no Job is produced at all.

**Continuous-readiness window (containerd-gc-storage and config-backup)**: `containerd-gc-storage-job-failed` and `config-backup-job-failed` use `min_over_time((max by (node) (kube_node_status_condition{node="k3s-nas", condition="Ready", status="true"}))[26h:1m]) == 1` — a 26-hour window that exceeds their 24-hour backup interval — rather than an instantaneous check. This ensures at least one full scheduled run has elapsed while the node was continuously healthy before a stale failed-job metric can trigger the alert. When the NAS returns after an offline period, the guard remains `false` for up to 26 hours, suppressing spurious alerts from jobs that failed during the downtime. Once the window elapses and a fresh successful run clears the stale metric, the guard becomes irrelevant; if a genuine failure occurs with the node continuously Ready for 26h, the alert fires correctly. The `for: 5m` debounce adds extra protection against flapping during node-Ready transitions. The Immich backup rule used to mirror this approach with a 7-hour window, but that guard suppressed genuine failures (see above) and was replaced with the `reason!="DeadlineExceeded"` filter instead. `config-backup-players-job-failed` deliberately does not join this family — its 01:00 schedule on the always-on node makes a 26-hour continuous-Ready requirement essentially unsatisfiable, so it uses the `reason!="DeadlineExceeded"` filter instead, same as Immich.

The guard must aggregate with `max by (node)` inside a subquery (`[26h:1m]`) rather than apply `min_over_time` directly to the bare selector, because `min_over_time` operates per time series, not per node. When kube-state-metrics restarts with a new pod IP, the `instance` label on `kube_node_status_condition` changes, so Prometheus starts a brand-new series while the old one goes stale — but the old series' last-known value is still visible inside the 26-hour lookback window and satisfied `== 1` for up to 26 hours after the pod that produced it was gone. On 2026-08-11, this let a `k3s-nas` outage that started at 02:05Z produce a spurious `Config Backup Job Failed` alert (issue #793) even though the guard should have suppressed it. Wrapping the selector in `max by (node) (...)` collapses all concurrent series for the node into one before the subquery samples it, so a dead series (which goes stale after ~5 minutes with no new scrapes) can no longer prop the guard up. Any future `_over_time` guard built on kube-state-metrics series needs the same treatment.

**"Running Too Long" alert** (`uid: immich-db-backup-duration-exceeded`): This alert fires when an active Immich DB backup job has been running for more than 10 minutes (`time() - kube_job_status_start_time > 600`, joined with `kube_job_status_active > 0`), gated by the k3s-nas readiness guard (`and on() kube_node_status_condition{node="k3s-nas", ...} == 1`). It uses `noDataState: OK` so silence between runs does not generate synthetic alerts. The k3s-nas guard prevents false positives when the NAS is offline and the pod is simply waiting for the NFS PVC mount (up to `activeDeadlineSeconds: 1800`, 30 minutes). The `pg_dump` process itself has no internal timeout — a hung dump keeps this alert firing (`for: 0s`) until the job's own `activeDeadlineSeconds: 1800` (30 minutes) kills it, so the alert can stay active for up to 20 minutes past its own 10-minute threshold. Routing is handled by the `.*Running Too Long` pattern in the CronJob alert receiver matcher.

### Node Health Alerts

Alert rules fire on node-level disk conditions that precede kubelet DiskPressure eviction:

| Rule | Condition | Threshold | Severity |
|------|-----------|-----------|----------|
| Node Disk Pressure | `kube_node_status_condition{condition="DiskPressure"} == 1` | 5m pending | critical |
| Node Filesystem Almost Full | root filesystem < 15% free | 10m pending | warning |
| Node Filesystem Critical | root filesystem < 5% free | 2m pending | critical |

These alerts fire to Slack and create GitHub Issues. They provide early warning before pods start cycling on k3s-nas. The node-exporter DaemonSet is pinned to `system-node-critical` priority so it survives kubelet eviction during a DiskPressure incident, keeping Prometheus metrics flowing. See [docs/nas-k3s.md](nas-k3s.md#diskpressure-recovery) for the recovery runbook.

### Cluster DNS

CoreDNS's `forward` plugin snapshots `/etc/resolv.conf` once at pod start. On 2026-08-15 21:17 UTC the `k3s` node's NetworkManager-managed resolv.conf changed underneath a 6-day-old CoreDNS pod, leaving it forwarding to a dead upstream; every external lookup returned SERVFAIL for ~35h (until a manual `kubectl rollout restart deployment coredns -n kube-system` at 2026-08-17 09:16 UTC) with nothing watching, breaking every Flux `HelmRepository` and several NAS-dependent backup CronJobs. See [docs/infrastructure-overview.md](infrastructure-overview.md) for the incident history — this is the second CoreDNS-upstream failure in three days from the same root cause (the node's mutable resolv.conf).

Two Grafana rules (folder `Alerts`, group `Cluster DNS`) now watch CoreDNS's own metrics: `CoreDNS SERVFAIL Rate High` and `CoreDNS Upstream Unreachable` (see table above). Both route to the `Slack - DNS` contact point via the `^CoreDNS.*` matcher, same as every other Slack-routed alert family in this stack.

The fastest signal is the Gatus `Cluster DNS` endpoint (`apps/gatus/config.yaml`), which queries `10.43.0.10` (CoreDNS's ClusterIP) directly for `github.com` every 60s — with `failure-threshold: 3` it turns red roughly 3 minutes into an outage, well before the 5–10 minute Grafana `for:` windows elapse.

**During a *total* external-DNS outage, neither Slack nor the GitHub-issues webhook can deliver until DNS recovers** — both need to resolve an external hostname through the very resolver that's broken. Grafana's Alertmanager retries on `group_interval`/`repeat_interval`, so the notification lands once CoreDNS is fixed, but it will read as "resolved" rather than "firing" if the fix happens first. The one signal that stays live throughout is the Gatus dashboard itself: a browser reaches it via the router's DNS, not CoreDNS, so it goes red immediately and stays visible for the duration of the outage.

### PVC Capacity Alerts

Alert rules fire when local-path PVC usage crosses two thresholds:

| Rule | Threshold | Pending | Severity |
|------|-----------|---------|----------|
| PVC Usage Warning | > 80% | 10 min | warning |
| PVC Usage Critical | > 90% | 5 min | critical |

The 10-minute pending on the warning rule avoids false positives during Prometheus TSDB compaction. The 5-minute pending on critical provides faster notification at the more dangerous threshold.

**PromQL** (local-path only, joined with kube-state-metrics for storage class filtering):
```promql
(
  kubelet_volume_stats_used_bytes
  / kubelet_volume_stats_capacity_bytes
)
* on(namespace, persistentvolumeclaim) group_left(storageclass)
  kube_persistentvolumeclaim_info{storageclass="local-path"}
* 100
```

Evaluation interval: 5 minutes. Rules are provisioned in the `Alerts` folder.

**Services monitored** (local-path PVCs with defined limits):
- Prometheus: 20 GB, 30-day retention (highest risk — cascading failure if full)
- Immich PostgreSQL: 10 GB
- Grafana: 5 GB

**Note on cascading failure**: If Prometheus fills its PVC and crash-loops, Grafana alerting cannot evaluate queries against it, so the alert cannot fire. The 80% warning threshold provides early warning well before this failure mode. A truly resilient solution would require an external watchdog beyond the scope of this stack.

### Proxmox Hardware Alerts

| Rule | Condition | Threshold | Severity |
|------|-----------|-----------|----------|
| Proxmox CPU Temperature High | CPU package temp (max over k10temp/coretemp) sustained | > 80°C for 5m | warning |
| Proxmox CPU Temperature Critical | CPU package temp sustained near thermal throttling/shutdown | > 90°C for 2m | critical |
| Proxmox NVMe Temperature High | NVMe composite temp sustained | > 70°C for 5m | warning |
| Proxmox NVMe Temperature Critical | NVMe composite temp sustained near thermal throttling | > 80°C for 2m | critical |

Uses `node_hwmon_temp_celsius{instance="proxmox"}` from the `proxmox-node-exporter` scrape job. Routes via the `Proxmox.*` matcher to the Slack - Proxmox contact point.

**`chip` vs `chip_name`**: In `node_exporter`, the `chip` label on `node_hwmon_temp_celsius` is the sysfs device path (e.g. `pci0000:00_0000:00:18_3`), not the driver name — matching `chip=~".*k10temp.*"` against it never matches anything. The driver name is exposed separately as `node_hwmon_chip_names{chip="...", chip_name="k10temp"} 1`. The CPU alert queries and the "CPU Package Temp" dashboard panel join through it: `node_hwmon_temp_celsius{instance="proxmox"} and on(instance, chip) node_hwmon_chip_names{instance="proxmox", chip_name=~"k10temp|coretemp"}`. Any new sensor alert on `chip` must use the same join, or it will silently match zero series. Verify chip names on the host with:

```bash
curl -s http://192.168.0.200:9100/metrics | grep node_hwmon_chip_names
```

**`noDataState`**: The CPU warning rule (`proxmox-cpu-temp-high`) uses `noDataState: NoData` — this is deliberate, so a query that stops matching (bad matcher, exporter down) surfaces as a `DatasourceNoData` alert rather than silently sitting in `OK` forever, which is exactly the failure mode that made the original `chip=~".*k10temp.*"` matcher invisible for months. The CPU critical rule and both NVMe rules keep `noDataState: OK`, since a routine Proxmox reboot briefly interrupting scrapes shouldn't also page critical.

**Safe temperature ranges** (from issue #652, 7-day chart ending 2026-07-09; ventilation was installed on the final day, visibly lowering all series):

| Sensor | Chip | Normal (observed) | Warn | Critical | Hardware limit |
|--------|------|--------------------|------|----------|-----------------|
| CPU package (Tctl) | `k10temp` | 55–70°C | 80°C | 90°C | Tjmax 95°C |
| iGPU edge | `amdgpu` | 43–52°C | — | — | ~100°C |
| NVMe composite | `nvme` | 34–52°C | 70°C | 80°C | throttles ~80°C |

No alert is defined for the iGPU sensor — it stayed well under any AMD APU thermal limit throughout the observation window and has no dedicated Prometheus metric worth thresholding yet.

### Contact Points

Grafana routes alerts via five contact points. All Slack contact points share the `grafana-slack-webhook` Kubernetes secret (key: `webhook-url`), injected as `SLACK_WEBHOOK_URL` via `envValueFrom` and referenced in `settings.url` as `$__env{SLACK_WEBHOOK_URL}`. The `optional: true` flag prevents Grafana from crashing if the secret is absent.

| Contact Point | Mechanism | Purpose |
|--------------|-----------|---------|
| `Slack - PVC` | Slack webhook | PVC capacity alerts |
| `Slack - CronJobs` | Slack webhook | CronJob failure/schedule alerts |
| `Slack - Node` | Slack webhook | Node health alerts (`alertname =~ "Node.*"`) |
| `Slack - Proxmox` | Slack webhook | Proxmox hardware alerts (`alertname =~ "Proxmox.*"`) |
| `GitHub Issues` | `grafana-github-alerts` webhook | Creates/updates GitHub issues for persistent alerts |

### Notification Routing Policy

Routes are evaluated in order under `alerting.policies.yaml` in the HelmRelease:

| Route | Matcher | Group by | Repeat | `continue` |
|-------|---------|----------|--------|------------|
| Immich Database Is Empty | `alertname =~ "^Immich Database Is Empty$"` | `alertname` | 720h | no |
| GitHub Issues | `alertname !~ KubeNodeNotReady\|KubeNodeUnreachable\|KubeletDown` | `alertname` | 24h | yes |
| Slack - PVC | `alertname =~ "PVC.*"` | `namespace`, `persistentvolumeclaim` | 4h | no |
| Slack - Node | `alertname =~ "Node.*"` | `alertname`, `node` | 4h | no |
| Slack - Proxmox | `alertname =~ "Proxmox.*"` | `alertname` | 4h | no |
| Slack - CronJobs | `alertname =~ ".*Job.*\|.*Schedule.*\|.*Running Too Long"` | `alertname` | 4h | no |

**Node offline alert suppression** (`ryzen` and `k3s-nas` nodes): The GPU worker (`ryzen`, 192.168.0.69) and NAS worker (`k3s-nas`) go offline regularly in normal homelab operation. Three built-in chart alerts fire when a node is unreachable — `KubeNodeNotReady`, `KubeNodeUnreachable`, and `KubeletDown` — creating noisy GitHub issues for expected transient outages. Suppression is applied at two levels:

1. **PrometheusRule level**: The three alerts are disabled via `defaultRules.disabled` and replaced with custom rules in `additionalPrometheusRulesMap` that exclude `ryzen` and `k3s-nas` from the expression (`node!~"ryzen|k3s-nas"`). These alerts never enter the alerting system for those two nodes. The custom `KubeletDown` rule uses `up{job="kubelet", metrics_path="/metrics", node!~"ryzen|k3s-nas"} == 0` (not `absent()`) so the `node` label is preserved for the exclusion filter.

2. **Routing level** (belt-and-suspenders): The `GitHub Issues` route has `object_matchers: [["alertname", "!~", "KubeNodeNotReady|KubeNodeUnreachable|KubeletDown"]]`, preventing any leakage (e.g., during alertmanager config reload lag) from creating GitHub issues.

3. **External monitors** (out of scope for this repo): Alerts filed by monitoring systems outside the cluster — recognisable by titles like `[k3s] Node NotReady: <node>` with body fields `First seen` / `Last seen` / `Occurrences` (distinct from the in-cluster `grafana-github-alerts` format of `[Alert] <alertname>` with `grafana-alert` label) — cannot be suppressed by configuration in this repository. Issues filed against `ryzen` (GPU worker) or `k3s-nas` (NAS worker) represent expected transient outages and should be closed as `wontfix` with a comment referencing this section. `[k3s] Flux HelmRelease NotReady: default/kube-prometheus-stack` issues from the same external monitor are the exception: they had a distinct, fixable cause — Helm's readiness wait on the node-exporter DaemonSet — addressed by `disableWait: true` (see [kube-prometheus-stack (HelmRelease)](#kube-prometheus-stack-helmrelease) above). Do not close new instances as `wontfix` without first checking that the HelmRelease actually settles within a minute of a values change.

Disk/filesystem node alerts (`NodeDiskPressure`, `NodeFilesystemAlmostFull`, `NodeFilesystemCritical`) are NOT suppressed — they still create GitHub Issues and Slack notifications.

The `continue: true` on the `GitHub Issues` route means any alert not in the exclusion list goes to GitHub **and** continues evaluation to the appropriate Slack route. All PVC, CronJob, and node disk/filesystem alerts therefore create GitHub Issues in addition to Slack notifications.

GitHub Issues group wait is 1m; all Slack routes use 30s group wait.

**Known standing conditions**: The `GitHub Issues` route matches on `alertname` only and carries no severity filter, so *any* new alert rule files a GitHub issue by default. A condition that is known, permanent, and only resolvable by manual work must therefore be given a terminal route (no `continue: true`) placed **before** the `GitHub Issues` route, which stops evaluation and keeps the alert Slack-only and visible in the Grafana UI. The `Immich Database Is Empty` route (see table above) is the first example of this idiom — reuse it for future known conditions rather than adding exclusion regexes to `GitHub Issues` or a severity filter to the alert rule.

### Grafana GitHub Alerts

`apps/monitoring/grafana-github-alerts/` is an in-cluster Python webhook receiver that bridges Grafana alert firings to GitHub issues on the `St-John-Software/fleet-infra` repository.

**How it works**:
```
Grafana alert fires
  → POST to grafana-github-alerts:8080/webhook
  → search GitHub for open issue with label "grafana-alert" + matching title "[Alert] {alertname}"
  → if not found: create new issue with occurrence tracking table in body
  → if found: edit issue body to update "Last Occurrence" and increment "Occurrences" count
  → on resolve: edit body with resolved timestamp, then close the issue
```

The service uses Python stdlib only (`urllib`, `json`, `re`) — no pip installs or external dependencies. It runs as a non-root user with a read-only root filesystem.

**Secret** (imperative, never in Git):
```bash
kubectl create secret generic grafana-github-token \
  --from-literal=token=<GITHUB_PAT> \
  -n default
```
The PAT must have `Issues: Read & Write` and `Metadata: Read` permissions. The key name must be exactly `token`.

**Webhook shared secret**: stored as a SOPS-encrypted Secret at `apps/monitoring/grafana-github-alerts/shared-secret.enc.yaml`, decrypted by Flux's `kustomize-controller` at reconcile time using the cluster age key in `flux-system/sops-age`. The shared secret authenticates Grafana's POST requests to the webhook receiver — both the Grafana pod and the webhook pod read `secretKeyRef.name: grafana-webhook-shared-secret` from `default`. To rotate: edit the file with `sops apps/monitoring/grafana-github-alerts/shared-secret.enc.yaml`, update the `token` value, commit, and push. After Flux reconciles, run `kubectl rollout restart deployment/grafana-github-alerts deployment/kube-prometheus-stack-grafana -n default` so both pods pick up the new token.

**NetworkPolicy**: `grafana-github-alerts-networkpolicy.yaml` restricts ingress to port 8080 on the webhook receiver to pods matching `app.kubernetes.io/name: grafana` only. This prevents other in-cluster workloads from calling the webhook directly (which would allow them to create or close GitHub issues using the webhook's `GITHUB_TOKEN`). The token is never exposed outside the cluster; the NetworkPolicy is defence-in-depth against cluster-internal abuse.

**Prometheus NetworkPolicy**: `prometheus-networkpolicy.yaml` restricts Prometheus's ingress on port 9090 to the `traefik` namespace, the Grafana datasource, and Gatus, plus a portless self-scrape rule so Prometheus can keep scraping its own pod (9090) and the `prometheus-config-reloader` sidecar (8080). Without it, unauthenticated in-cluster pods could query the full Prometheus API (all cluster metrics) directly on the ClusterIP, bypassing the ForwardAuth middleware on the ingress entirely.

**Deduplication**: Searches GitHub Issues API for open issues with the `grafana-alert` label and `[Alert] {alertname}` in the title. Repeat firings of the same alert update the existing issue rather than creating duplicates. This prevents noisy GitHub notifications for flapping alerts.

**Note on token expiry**: Fine-grained PATs have an expiration date. If the token expires, the pod continues running but all GitHub API calls return 401. Failures are logged to stdout — monitor pod logs if alerts stop appearing as GitHub issues.

## Custom Dashboards

Dashboards are deployed as ConfigMaps labeled `grafana_dashboard: "1"`. The Grafana sidecar automatically picks them up.

**PVC Capacity dashboard** (`dashboards/pvc-capacity-dashboard.yaml`): Shows all PVC usage as a table (all PVCs, with color thresholds) and a horizontal bar gauge filtered to local-path PVCs. The table intentionally includes all PVCs so it doubles as a general PVC overview for a future Kubernetes cluster overview dashboard.

**Proxmox Temperature dashboard** (`dashboards/proxmox-temperature-dashboard.yaml`): Shows Proxmox host CPU package temperature as a stat panel (thresholds at 70°C yellow / 80°C red) and all hwmon sensor readings as a time series. Requires `prometheus-node-exporter` installed on the Proxmox host — see "Proxmox Node Exporter (host-side setup)".

**Authentik dashboard** (`dashboards/authentik-dashboard.yaml`): Tracks Authentik auth latency percentiles, request throughput, failed authentications, flow execution time, and worker queue depth, sourced from `authentik_outpost_proxy_request_duration_seconds` and related Authentik-exported metrics.

### Adding a New Dashboard

1. Create a ConfigMap in `monitoring/dashboards/`:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: my-dashboard
     labels:
       grafana_dashboard: "1"
   data:
     my-dashboard.json: |
       { ... Grafana dashboard JSON ... }
   ```
2. Add it to `monitoring/kustomization.yaml` under `resources`
3. The sidecar will auto-inject it into Grafana

Alternatively, use `gnetId` in the HelmRelease values to auto-provision dashboards from Grafana.com.

## Modifying the Stack

The entire monitoring config is in `monitoring/kube-prometheus-stack.yaml` as HelmRelease values. Changes to Grafana settings, Prometheus retention, scrape configs, or feature toggles are all made in that single file.

For new exporters, create a subdirectory under `monitoring/` with deployment + service manifests and add a corresponding `additionalScrapeConfigs` entry in the HelmRelease.
