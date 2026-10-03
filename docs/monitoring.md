# Monitoring Stack

**Depth:** **Reference**
**Read this when:** touching Prometheus, Grafana, alert rules, dashboards, or the PVE exporter.
**Read instead:** [config-backups.md](config-backups.md) or [forgejo-backups.md](forgejo-backups.md) for backup-specific CronJob alerts, or [logging.md](logging.md) for Loki/Promtail pod log aggregation.

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
├── postgres-exporter/
│   ├── deployment.yaml                  # Shared PostgreSQL metrics exporter (port 9187)
│   └── service.yaml
├── grafana-github-alerts/
│   ├── deployment.yaml                  # Python webhook receiver (port 8080)
│   ├── service.yaml
│   ├── server.py                        # webhook script (stdlib only), shipped via configMapGenerator
│   ├── test_server.py                   # unit tests, run by the grafana-github-alerts-tests CI job
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

**No Helm wait (`disableWait: true` on install, upgrade and rollback)**: Helm's `--wait` gates release success on every resource in the chart reaching readiness, including the `prometheus-node-exporter` DaemonSet. Helm's DaemonSet check requires `numberReady >= desiredNumberScheduled - maxUnavailable`, which here is `3 - 1 = 2`. `ryzen` (GPU worker) and `k3s-nas` (storage worker) are powered off for most of the day, and the node-lifecycle controller marks their node-exporter pods `Ready=False` while the node is `NotReady`. With one worker down the check still passes (`numberReady: 2`); with **both** down it reports `numberReady: 1` and can never pass — so any values change or Renovate chart bump landing in that window blocked for the full 20-minute timeout, failed with `context deadline exceeded`, then rolled back and blocked *again* on the same DaemonSet, repeatedly. Because a rollback renders the previous known-good manifests, its failing too proves the wait — not the chart values — is the blocker. Confirmed on 2026-08-21: upgrades v119/v120 at 00:56Z/01:02Z succeeded while only `ryzen` was offline; every attempt after `k3s-nas` went `NotReady` at 02:03:54Z failed. That intermittency is why the `[k3s] Flux HelmRelease NotReady: default/kube-prometheus-stack` issue series (#336, #341, #348, #491, #496, #577, #584, #878) recurred for months without diagnosis. Note that `kubectl get pods` prints `1/1` for those pods — that is *container* readiness; the DaemonSet counts the pod `Ready` **condition**. With `disableWait: true` the release is applied and reported succeeded as soon as the manifests land; the `timeout: 20m` values are kept because Helm still waits on chart hooks such as the `admission-create` webhook-certgen Job. The trade-off is that Flux no longer auto-detects or auto-rolls-back a functionally broken upgrade, and the `slack-errors` Flux alert in `clusters/my-cluster/flux-system/notifications.yaml` will no longer fire for one — that job now belongs to the Gatus checks on `kube-prometheus-stack-grafana:80/api/health` and `kube-prometheus-stack-prometheus:9090/-/healthy` in `apps/gatus/config.yaml`, and a HelmRelease that stays `Ready=False` because of a broken upgrade now also fires the `Flux HelmRelease Not Ready` Grafana rule (see [Flux Reconciliation Alerts](#flux-reconciliation-alerts)) after 30m — long enough that a normal `disableWait: true` upgrade, which now settles in seconds, never trips it. Note also that a stuck rollback silently reverts recently merged values: during the #878 window the CoreDNS alert rules merged in #876 were rolled back out of the live `kube-prometheus-stack-grafana` ConfigMap while Git still showed them present (they were reinstated by the v120 upgrade).

**Helm `tpl` / Grafana template incompatibility**: The Grafana subchart (`_config.tpl`) runs Helm's `tpl` function over the `alerting.contactpoints.yaml` values block. This causes any `{{ }}` expressions in contact point `settings` (title, text, message, etc.) to be interpreted as Go/Helm templates. Grafana uses its own notification template functions (e.g., `toUpper`, `range .Alerts`) that are not registered in Helm's Sprig FuncMap — so including them in `settings` values causes a render failure at `helm upgrade` time, not at runtime. **Do not add custom `title`, `text`, or other template expressions in contact point settings.** Use plain strings or Grafana's `$__env{VAR}` syntax (which passes through `tpl` safely since it contains no `{{ }}`). If rich notification formatting is needed, use `alerting.notificationTemplates` with a named template reference in the contact point settings (the template body can use Grafana functions; only the reference string passes through `tpl`). Alert rule `annotations` (in `rules.yaml`) are processed by Prometheus, not Helm, so they are not affected — but if they do pass through `tpl` in a future chart version, use the Go escape syntax `{{ "{{" }}` to output a literal `{{`.

### Grafana

| Setting | Value |
|---------|-------|
| Domain | grafana.home.bstjohn.net |
| Port | 8080 |
| Storage | 5 GB, local-path |
| Auth | Secret `grafana-admin-secret` (keys: `admin-user`, `admin-password`) |
| Init chown | Disabled (fails on existing PVCs with subdirectories) |

**SSO**: Grafana uses Authentik's ForwardAuth middleware on its ingress plus `auth.proxy` for header-based session mapping. The Grafana and Prometheus ingresses (`.home` and `.ext`) use the `authentik-auth-basic(-ext)` chain, which lets an HTTP Basic Authentik app password reach the outpost and strips it before the backend; this is how Claws' `claws-reader` (Viewer) and `claws-admin` (Admin) service accounts query Grafana and Prometheus — see [authentik.md](authentik.md), "Claws service accounts". `auto_sign_up: true` — a Grafana user is created on first proxy login, including for those accounts. A NetworkPolicy (`grafana-networkpolicy.yaml`) restricts Grafana's ingress on port 3000 to pods in the `traefik` namespace, the Gatus health check, and Prometheus (self-monitoring scrape), preventing in-cluster header spoofing from any other pod. `whitelist: 10.42.0.0/16` is a secondary safeguard. Local admin login remains enabled as a fallback. Org role is derived from Authentik group membership rather than Grafana's database — see [authentik.md](authentik.md), "Grafana Integration".

**Public dashboards (wall display)**: `grafana.home.bstjohn.net` exposes three paths with no auth: `/public-dashboards/*`, `/api/public/*`, and `/public/*` (static frontend assets only — no instance data). This is done via `skip_path_regex` on the `grafana-forward-auth-home` proxy provider in `apps/authentik/configmap-blueprints.yaml`, not a second Ingress — `scripts/check-ingress-uniqueness.sh` rejects two Ingress/IngressRoute resources on one hostname. `security.allow_embedding: true` in `grafana.ini` is instance-wide and removes `x-frame-options` from both `grafana.home.bstjohn.net` and `grafana.ext.bstjohn.net`. Publishing a dashboard (via the `/api/dashboards/uid/<uid>/public-dashboards` API) is runtime Grafana DB state, not GitOps — the resulting access token is regenerated if Grafana's `local-path` PVC is ever lost, invalidating any URL held elsewhere (e.g. the `dashpi` wall display in `nixos-config`). Only dashboards with no template variables can be published; of the ConfigMap dashboards in `apps/monitoring/dashboards/`, `pvc-capacity`, `authentik-sso` and `proxmox-temperature` qualify (`"templating": { "list": [] }`), while the stock kube-prometheus-stack dashboards use `$datasource`/`$node` variables and render empty if published.

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

**Headlamp metrics charts**: Headlamp's bundled prometheus plugin auto-detects this Prometheus via the `headlamp-prometheus: "true"` label on the `kube-prometheus-stack-prometheus` Service (`prometheus.service.labels` above) plus the `services/proxy` grant in `read-only-cluster-viewer` (`clusters/my-cluster/config/rbac/clusterrole.yaml`). See [apps-overview.md](apps-overview.md#headlamp-helm-chart-040x) for the detection order and why `pods/proxy` is not granted.

### Scrape Configurations

Seven additional scrape configs defined in `additionalScrapeConfigs`. Loki is the one in-cluster target that is instead scraped via a chart-provided ServiceMonitor (`monitoring.serviceMonitor.enabled: true` in `apps/monitoring/loki.yaml`) rather than a static `additionalScrapeConfigs` job, which requires the ServiceMonitor to carry the `release: kube-prometheus-stack` label so the Prometheus CR's `serviceMonitorSelector` picks it up.

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
task execution latency, and worker health. The `Authentik` Grafana alert group (see below)
consumes `django_db_errors_total`, `authentik_tasks_errors_total`, `authentik_tasks_total`,
`authentik_tasks_queued`, and `authentik_tasks_workers` from this target.

#### gatus

```yaml
job_name: gatus
metrics_path: /metrics
static_configs:
  - targets: ["gatus.default.svc.cluster.local:8080"]
```

Scrapes Gatus uptime monitoring metrics. Provides endpoint response times, success/failure
rates, and alert status. Uses FQDN since Gatus runs in the `default` namespace.

#### jellyfin-reconciler (library scan health)

```yaml
job_name: jellyfin-reconciler
metrics_path: /metrics
static_configs:
  - targets: ["jellyfin.default.svc.cluster.local:9101"]
```

Scrapes the `config-reconciler` sidecar in the Jellyfin pod (#1075), which owns the library-scan
cadence: it starts a scan only when the NAS is reachable and the media mount is populated, at
most once an hour. Metrics: `jellyfin_reconciler_up` (sidecar liveness), `jellyfin_media_mount_ready`
(NAS reachable and `/media` populated right now), `jellyfin_library_scan_last_success_timestamp_seconds`
(end time of the last completed scan), and `jellyfin_library_scan_triggers_total` (scans started by
this sidecar since it last restarted — a counter that resets on pod restart, so use it for rate, not
absolute count), and `jellyfin_reconciler_last_loop_timestamp_seconds` (last completed precondition
check, for staleness detection). `jellyfin_library_scan_last_success_timestamp_seconds` combined with
`jellyfin_media_mount_ready` is the basis for a future "no scan in N days while the NAS was awake" alert.

#### sonarr-reconciler / radarr-reconciler (import and request health)

```yaml
job_name: sonarr-reconciler
metrics_path: /metrics
static_configs:
  - targets: ["sonarr.default.svc.cluster.local:9101"]
job_name: radarr-reconciler
metrics_path: /metrics
static_configs:
  - targets: ["radarr.default.svc.cluster.local:9101"]
```

Scrapes the shared `config-reconciler` sidecar in the Sonarr and Radarr pods (`apps/servarr/reconcile.py`,
see [servarr.md](servarr.md#reconciler-sidecar)). Metrics, all labelled `app`: `servarr_reconciler_up`,
`servarr_reconciler_last_loop_timestamp_seconds`, `servarr_queue_import_blocked_seconds{download_id,title,reason}`
(seconds an import-blocked download has been seen), `servarr_auto_import_total{result}` (`imported`,
`skipped`, `failed`), `servarr_request_stalled{title,reason,rejections}` (value 1; reasons `unmonitored`,
`searching`, `no_acceptable_release`, `search_failed`), `servarr_request_source_up{source}` (1 when the last
poll of that Seerr/Overseerr instance succeeded, 0 when it failed or has no key) and
`servarr_request_actions_total{action}` (`remonitored`, `season_search`, `release_search`). Counters reset on pod restart. Both pods run on
`k3s-nas`, so the targets are down while the NAS sleeps. Port 9101 is admitted from Prometheus by each
app's NetworkPolicy.

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

#### postgres-exporter (shared PostgreSQL)

```yaml
job_name: postgres-exporter
static_configs:
  - targets: ["postgres-exporter.default.svc.cluster.local:9187"]
```

Scrapes `postgres_exporter` v0.20.1 in `apps/monitoring/postgres-exporter/`, which connects to
the shared instance in [`apps/postgres/`](postgres.md). It connects **as the superuser
deliberately**: a non-superuser sees NULL `state` and `usename` for every backend it does not
own, which would defeat the per-role attribution the exporter exists for, and a superuser can
still claim one of the 5 slots held by `superuser_reserved_connections` while the instance is
otherwise full — so the exporter keeps reporting through exactly the squeeze it is meant to
explain (#1235). The password comes from the in-cluster `postgres-superuser` Secret.

There is no custom query file and no `--extend.query-path` (deprecated upstream): the default
`stat_activity` collector already emits
`pg_stat_activity_count{datname,state,usename,application_name,backend_type,wait_event_type,wait_event}`
— the attribution — and the `settings` collector emits `pg_settings_max_connections`, the
ceiling. Together they are the saturation ratio the alerts below use.

#### flux controllers

Unlike the jobs above, this one is not an `additionalScrapeConfigs` static target — it is a
`PodMonitor` added via `prometheus.additionalPodMonitors` in the HelmRelease values (sibling
of `prometheusSpec`), because the chart template (`templates/prometheus/podmonitors.yaml`)
stamps `release: kube-prometheus-stack` on the rendered object automatically, so the
load-bearing selector label (see [logging.md](logging.md#health), "Health") can never be
forgotten the way a hand-written `PodMonitor` manifest in `apps/` could be. `namespaceSelector`
is pinned to `flux-system`; `selector.matchExpressions` matches `app in
(source-controller, kustomize-controller, helm-controller, notification-controller)` — each
controller pod carries `app: <controller-name>` — deliberately excluding the tofu-controller,
which uses different labels. The single `podMetricsEndpoints` entry scrapes the named
`http-prom` port (8080) and keeps only `Running` pods. Prometheus's
`podMonitorNamespaceSelector` is `{}` (all namespaces) and `flux-system` already has the
`allow-scraping` NetworkPolicy admitting port 8080 from any namespace, so no NetworkPolicy
change was needed.

This yields `gotk_reconcile_duration_seconds*`, `controller_runtime_*` and `workqueue_*` only.
**Flux v2 controllers do not emit `gotk_reconcile_condition`** — `kustomize-controller` and
`helm-controller` reconcilers only call `Metrics.RecordDuration`, and the upstream Flux metrics
docs list no per-object readiness gauge for the controllers — so per-object Ready state cannot
come from this scrape target. It instead comes from kube-state-metrics custom resource state
(the `kube-state-metrics:` subchart values block next to `prometheus-node-exporter:` in the
same HelmRelease), which watches `Kustomization` (`kustomize.toolkit.fluxcd.io/v1`) and
`HelmRelease` (`helm.toolkit.fluxcd.io/v2`) objects via an added `rbac.extraRules` grant and
exports one `gotk_resource_info` info metric per object with labels
`customresource_kind`, `exported_namespace`, `name`, `ready`, `suspended`, `revision`, plus
`source_name` (Kustomization) or `chart_name`/`chart_source_name` (HelmRelease) — this is the
`fluxcd/flux2-monitoring-example` upstream pattern. `collectors: []` /
`--custom-resource-state-only` are deliberately **not** set, since the CronJob/PVC/node rules
in this stack depend on kube-state-metrics' default core collectors staying enabled. Only
`Kustomization` and `HelmRelease` are configured; Flux source kinds are out of scope. See
[Flux Reconciliation Alerts](#flux-reconciliation-alerts) for the rules built on it.

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
| `PVE_VERIFY_SSL` | `true` (verified against the PVE cluster CA) |
| `REQUESTS_CA_BUNDLE` | `/etc/pve-ca/tls.ca`, from Secret `proxmox-root-ca` (`apps/proxmox/root-ca.enc.yaml`) |

The Prometheus scrape config passes `target: 192.168.0.200` as a parameter — the exporter connects to that Proxmox host.

The exporter authenticates with static `PVE_USER`/`PVE_PASSWORD` on every scrape, so verification is pinned to the Proxmox cluster CA (`/etc/pve/pve-root-ca.pem`, expires 2033-12-04); if the node's cert is ever reissued by a different CA (e.g. an ACME cert on the PVE host), re-export the CA into `apps/proxmox/root-ca.enc.yaml` or scrapes will fail closed with an SSL error.

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

Grafana Unified Alerting (enabled by default in Grafana 9+) is used for alert rules. Alertmanager remains disabled — alerts route via Grafana directly to Slack. `PrometheusNotConnectedToAlertmanagers` is disabled via `defaultRules.disabled` because it fires permanently while Alertmanager is off by design. The rest of the chart's default `Kube*` PrometheusRules (`KubePodCrashLooping`, `KubePodNotReady`, `KubeContainerWaiting`, `KubeJobFailed`, `KubeDeploymentReplicasMismatch`, and others) stay enabled: Prometheus evaluates them and they are visible on its `Alerts` page, but since Grafana unified alerting does not read Prometheus-evaluated alerts and Alertmanager is off, nothing notifies on them — that gap is what the Grafana-provisioned `Workload Health` rules below exist to close.

**No AWTRIX, no watchdog pods.** When the #842 CoreDNS SERVFAIL incident (35h of undetected cluster-wide DNS failure) was scoped, @stjohnb explicitly rejected both a new watchdog pod ("I'm not sure about putting a new watchdog pod in") and routing alerts through the AWTRIX pixel-display proxy ("Do not use awtrix for alerts"), asking instead whether Prometheus/Grafana could cover it. New detection for cluster-health gaps should extend the existing Grafana alert rules and Slack/GitHub-Issues channels — the same channels every other alert in this repo uses — not a bespoke pod or a new notification target.

**UID constraint**: every provisioned `uid` — alert rules and contact-point receivers alike —
must be 40 characters or fewer and unique. Grafana rejects a longer UID at provisioning time,
and because the alerting provisioner is a required background service, one bad UID crash-loops
the entire Grafana pod rather than skipping the rule. `kustomize` and `kubeconform` cannot see
this (the YAML is valid), so `scripts/check-grafana-alert-uids.sh` gates it in CI and in
`task validate`. This bit once: `servarr-downloads-janitor-schedule-missed` (41 chars) took
Grafana down in #1081.

**`absent()` rules must use `noDataState: OK`**: `absent(v)` returns `1` only when `v` is
empty and returns *nothing* when `v` has samples, so for the `absent(up{job="x"} == 1)`
target-down idiom a healthy target produces NoData and a dead one produces a value. NoData is
the healthy branch; `noDataState: Alerting` inverts the rule into a guaranteed false positive
`for:` minutes after every Grafana restart (#1260). `scripts/check-grafana-nodata-state.sh`
gates this in CI and in `task validate`. The three rules on this idiom are
`kube-state-metrics-down`, `authentik-worker-down` and `postgres-exporter-target-down`.

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
| Postgres DB Backup Job Failed | `kube_job_status_failed > 0` for `postgres-db-backup-[0-9]+` with `reason!="DeadlineExceeded"` | 5m pending | critical |
| Postgres DB Backup Schedule Missed | No new job in >2 days (2x daily interval) (or, if never scheduled, CronJob created that long ago) | 5m pending | critical |
| Postgres DB Backup Job Stale | `postgres-db-backup` last success (or CronJob creation, if never successful) >14 days ago | 30m pending | warning |
| Servarr Downloads Janitor Job Failed | `kube_job_status_failed > 0` for `downloads-janitor-[0-9]+` with `reason!="DeadlineExceeded"` | 5m pending | warning |
| Servarr Downloads Janitor Schedule Missed | No new job in >2 days (2x daily interval) (or, if never scheduled, CronJob created that long ago) | 5m pending | warning |
| Datasette SQLite Sync Job Failed | `kube_job_status_failed > 0` for `datasette-sync-sqlite-[0-9]+` with `reason!="DeadlineExceeded"` | 5m pending | warning |
| Datasette SQLite Sync Job Stale | `datasette-sync-sqlite` last success (or CronJob creation, if never successful) >3 days ago | 30m pending | warning |
| Pages Janitor Job Failed | `kube_job_status_failed > 0` for `pages-janitor-[0-9]+` (no node guard) | 5m pending | warning |
| Pages Janitor Schedule Missed | No new job in >14 days (2x weekly interval) (or, if never scheduled, CronJob created that long ago) | 5m pending | warning |
| Migration Runner Job Failed | `max_over_time(kube_job_status_failed{job_name="migration-runner"}[20m]) > 0` | 5m pending | warning |
| Kube State Metrics Down | `absent(up{job="kube-state-metrics"} == 1)` | 15m pending | warning |
| Promtail DaemonSet Not Ready | `kube_daemonset_status_number_ready{daemonset="promtail"} - scalar(count(kube_node_status_condition{job="kube-state-metrics", condition="Ready", status="true"} == 1)) < 0` | 15m pending | warning |
| Loki Log Ingestion Stalled | `sum(increase(loki_distributor_lines_received_total[30m])) or on() vector(0)` < 1 | 30m pending | warning |
| Uncovered Job Failed | `kube_job_status_failed > 0` for the newest Job of any CronJob (or ownerless Job) not already covered by a rule above | 10m pending | warning |
| CoreDNS SERVFAIL Rate High | >5% of CoreDNS responses are SERVFAIL | 10m pending | critical |
| CoreDNS Upstream Unreachable | increase(coredns_forward_healthcheck_broken_total[10m]) > 0 | 5m pending | critical |

The containerd-gc alerts are split into two separate rules: `containerd-gc-job-failed` watches only the main-node job (`containerd-gc-[0-9]+`, runs at 04:00) and always alerts on failure regardless of NAS state. `containerd-gc-storage-job-failed` watches only the k3s-nas job (`containerd-gc-storage-[0-9]+`, runs at 04:30) and uses `min_over_time((max by (node) (kube_node_status_condition{node="k3s-nas", condition="Ready", status="true"}))[26h:1m]) == 1` — the node must have been continuously Ready for 26 hours before a failed job fires an alert. This 26-hour window ensures at least one full scheduled run has elapsed while the node was healthy; if that run failed, the alert fires. If k3s-nas was offline for days and just came back online, any stale failed jobs from that downtime are suppressed until the node has been up long enough for a fresh run to succeed (or fail genuinely). The `for: 5m` debounce prevents flapping when many series flip simultaneously on node-Ready transitions. This split exists because the main-node GC has no NAS dependency, so its failures are always genuine; the storage-node GC depends on k3s-nas being alive to schedule the pod.

The Immich backup alerts are split by Job failure reason for the same reason the containerd-gc alerts are split by node: an expected, known failure mode must not share a rule with a genuine one. `immich-db-backup-job-failed` excludes `reason="PodFailurePolicy"` (the empty-database refusal) alongside `reason="DeadlineExceeded"` (the NFS-Pending case), while `immich-db-empty` watches `reason="PodFailurePolicy"` exclusively.

`config-backup-job-failed` reuses the identical 26-hour `k3s-nas`-Ready guard for the same reason: the config backup mounts the NFS media share to write its archives, so every run while the NAS is powered off stalls on the mount and records a failure that is expected rather than actionable. Because the NAS is awake only ~02:03–03:03 nightly, that guard is close to permanently false — it cannot itself confirm the backup is alive, which is how six days of zero successful `config-backup` runs went unnoticed after its creation on 2026-08-07. `config-backup-job-stale` (14 days, `kube_cronjob_status_last_successful_time`) is what actually proves that backup alive. See [docs/config-backups.md](config-backups.md).

Every backup/GC CronJob-generated Job in `default` sets `ttlSecondsAfterFinished: 172800` (48h), so a Failed Job — and the `kube_job_status_failed` series these rules read — disappears two days after the run. `migration-runner` and `admission-error-reaper` are exceptions at 600s (see [docs/config-backups.md](config-backups.md)). The 48h TTL is deliberately far longer than the `for: 5m` on every rule here and longer than the 26h node-readiness guard on `config-backup-job-failed` and `containerd-gc-storage-job-failed`, both of which need the Job object to still exist when the guard finally lets them evaluate. Do not shorten it below 26h.

`migration-runner-job-failed` is the only rule in this group watching a plain Job rather than a CronJob-generated one, so its Job name is fixed (`migration-runner`) and it omits the `topk(1, kube_job_status_start_time...)` newest-job selector the others use. It needs `max_over_time(...[20m])` instead: `ttlSecondsAfterFinished: 600` deletes the finished Job and the `migrations` Kustomization re-applies it within its 1-minute interval, so the metric series vanishes for a minute or two every ~11 minutes and a bare `> 0` rule would flap fire/resolve indefinitely. It excludes no `reason` — unlike the NFS-dependent backup jobs, `DeadlineExceeded` here means a migration script hung past `activeDeadlineSeconds: 600` and is actionable.

`promtail-daemonset-not-ready` is the other non-CronJob rule in this group, alongside `kube-state-metrics-down`: it compares `kube_daemonset_status_number_ready` against a count of currently-Ready nodes (`scalar(count(kube_node_status_condition{condition="Ready", status="true"} == 1))`) rather than the DaemonSet's own `kube_daemonset_status_desired_number_scheduled`. The DaemonSet's desired count is *not* a safe denominator here: `nodeShouldRunDaemonPod` derives it from node selectors and taint tolerations only, never node readiness, and promtail's blanket `tolerations: [{operator: Exists, effect: NoSchedule}]` (see [docs/logging.md](logging.md#node-pinning)) tolerates the `not-ready`/`unreachable` taints a powered-off `k3s-nas`/`ryzen` acquires — so desired stays at 3 even though those nodes' promtail pods flip to `Ready=False`. Counting Ready nodes instead gives the true "should be running" population, so the rule stays quiet when `k3s-nas`/`ryzen` are powered off and fires only when promtail itself is unhealthy on nodes that are up. This is the compensating signal for the promtail HelmRelease's `disableWait: true` — see [docs/logging.md](logging.md#health). Like `kube-state-metrics-down`, its alertname matches no Slack route (`Slack - CronJobs` only matches `.*Job.*|.*Schedule.*|.*Running Too Long`), so it reaches a human only via the `GitHub Issues` route; this is deliberate rather than an oversight.

`config-backup-players-job-failed` (watching `config-backup-players.*`) takes the same approach as the Immich rule below rather than the 26-hour guard above: it filters on `reason!="DeadlineExceeded"`. That CronJob runs on the always-on `k3s` node, but its destination is the hard-mounted `media-pvc`, so a night the NAS is asleep produces a Job failure identical in shape to Immich's NFS-Pending case. The 26-hour Ready gate was rejected here because the NAS powers off at 03:03 nightly and would essentially never satisfy a 26-hour continuous-Ready requirement. See [docs/config-backups.md](config-backups.md#alerting).

`postgres-db-backup-job-failed` covers the shared-Postgres nightly dump (`apps/postgres/cronjob-db-backup.yaml`, 02:30, every application database except `immich` — today `authentik` and `garden`). It uses the `reason!="DeadlineExceeded"` filter rather than the 26-hour `k3s-nas`-Ready guard, for the same reason as the Immich and players rules: the job is pinned to `k3s-nas` and writes to the NFS media share, so on a night the NAS is asleep the pod never starts and `activeDeadlineSeconds: 1800` records an expected `DeadlineExceeded` failure. It filters no `PodFailurePolicy` reason because this CronJob defines no `podFailurePolicy` — the "no application databases exist yet" path exits **0** with a log line and produces no failed Job at all, so it is silent by construction and needs no exclusion. Because that `DeadlineExceeded` exclusion means the failed-job rule can be permanently quiet on a box that sleeps nightly, `postgres-db-backup-job-stale` (14 days, `kube_cronjob_status_last_successful_time`, warning) is what actually proves the backup alive — the same lesson `config-backup` taught after six days of zero successful runs went unnoticed. `postgres-db-backup-schedule-missed` (2 days, 2x the daily interval) watches the CronJob controller rather than the pod, so NAS downtime does not mask it. See [docs/postgres.md](postgres.md#backups).

`servarr-downloads-janitor-job-failed` covers `apps/servarr/downloads-janitor/` (`docs/servarr.md#downloads-janitor`), a daily 02:25 CronJob on `k3s-nas` that finds download data Transmission no longer owns. Unlike every other CronJob rule in this group, its job is deliberately dual-purpose: it exits non-zero both on a genuine failure (RPC unreachable, a `torrentCount` mismatch, a failed `rm`) and on "found orphans I am not allowed to delete yet" (the per-run cap tripped, or `DRY_RUN` is still `"true"` and orphans exist). `DRY_RUN` was flipped to `"false"` in #1121, so this rule is now quiet except on the cap/guard trips, the same as any other backup-style job; a firing means read the job log for the `level=error` line. It uses the `reason!="DeadlineExceeded"` filter rather than the 26-hour `k3s-nas`-Ready guard, for the same reason as `postgres-db-backup-job-failed`: the job is pinned to `k3s-nas`, which is powered off most of the day, so a Pending-then-deadline failure is expected, not actionable. There is deliberately no `-job-stale` companion rule: it was omitted because under `DRY_RUN: "true"` the job never succeeds while orphans exist, and it stays omitted because the `-schedule-missed` rule already covers a CronJob that stops running.

`datasette-sqlite-sync-job-failed` and `datasette-sqlite-sync-job-stale` cover `datasette-sync-sqlite` (`apps/datasette/cronjob-sync-sqlite.yaml`, 02:35), which snapshots the Sonarr, Radarr, Bazarr, Prowlarr, Seerr and Jellyfin SQLite databases into Datasette. It runs on `k3s` but reads the servarr databases from `config-backup`'s archives on the hard-mounted `media-pvc`, so the failed-job rule excludes `reason="DeadlineExceeded"` for the same NAS-asleep reason as `config-backup-players-job-failed`. Because that exclusion can make it permanently quiet, the stale rule (3 days, `kube_cronjob_status_last_successful_time`, creation-timestamp fallback) is what proves the snapshots fresh. The threshold is 3 days rather than the backups' 14 because the NAS is now woken nightly by Home Assistant, so three missed nights is actionable. Only a fully green run advances the success timestamp, so one persistently failing source also fires it. See [docs/datasette.md](datasette.md#sqlite-sources).

These alerts use `kube-state-metrics` (`kube_job_status_*`, `kube_cronjob_status_*`) and `topk(1, kube_job_status_start_time)` to only evaluate the most recent job per CronJob.

**`noDataState` semantics**: All CronJob rules now use `noDataState: OK`. Schedule-missed rules previously used `noDataState: NoData` on the theory that an absent series was itself evidence of a missed schedule, but that made them fire on any scrape gap: when the `k3s` node's container runtime restarted at 2026-08-10T16:52:50Z, taking down Prometheus and kube-state-metrics together, all three fired `DatasourceNoData` 30 seconds later and filed issues #783/#784/#785 (the `for: 5m` pending period is not applied to NoData transitions). The "never scheduled" case they were protecting is now encoded in the query itself via an `or (time() - max by (cronjob) (kube_cronjob_created{...}))` fallback — kube-state-metrics publishes no `kube_cronjob_status_last_schedule_time` series until `.status.lastScheduleTime` is set (issues #708, #772). Total loss of kube-state-metrics is covered explicitly by `kube-state-metrics-down`, which has a real 15-minute pending period. The `proxmox-cpu-temp-high` rule keeps `noDataState: NoData` — see the Proxmox section.

**No node-readiness guard on the Immich backup alert**: The `immich-db-backup-job-failed` PromQL expression filters on `reason!="DeadlineExceeded"` rather than gating on k3s-nas readiness. When the NAS is offline, the backup pod stalls in `ContainerCreating` waiting for the NFS PVC mount and is eventually killed by `activeDeadlineSeconds: 1800`, which kube-state-metrics reports as `kube_job_status_failed{reason="DeadlineExceeded"}` — that series is excluded, so the expected NFS-Pending case does not fire. Any other failure (Postgres unreachable, a rejected dump) surfaces a `kube_job_status_failed` series with a different `reason` (or, briefly, no `reason` label at all, which also satisfies `!=`) and fires regardless of NAS uptime. The rule previously gated on `min_over_time(kube_node_status_condition{node="k3s-nas", condition="Ready", status="true"}[7h]) == 1`, but because the NAS is deliberately powered off most of the time, that guard suppressed genuine backup failures along with the expected NFS-Pending ones — this is how three months of empty-database backups reported success without ever alerting (issue #698). `topk(1, kube_job_status_start_time)` scopes the alert to the most recent scheduled run, so once a later run succeeds the series drops out and the alert self-resolves under `noDataState: OK`. Severity is `critical`.

**No node guard on the Forgejo backup alert**: `forgejo-backup-job-failed` has never carried a `k3s-nas` readiness guard, unlike the historical Immich rule (see above — the Immich guard has since been removed in favor of `reason!="DeadlineExceeded"`). The Forgejo backup is split into two stages to avoid the NFS coupling that motivated Immich's guard in the first place: stage 1 (`forgejo-backup`, 02:30) dumps to a `local-path` PVC on the 24/7 node and mounts no NFS, so it has no expected-failure mode to suppress and any failure is real. The off-node copy is stage 2 (`forgejo-backup-offsite`, 03:00), whose nightly failures while the NAS is off are expected and are not alerted on at all — only 14 days of consecutive failure raises the warning-level `forgejo-offsite-backup-job-stale`. See [docs/forgejo-backups.md](forgejo-backups.md). The staleness rule anchors to `kube_cronjob_created` when no success has been recorded, because kube-state-metrics publishes no `kube_cronjob_status_last_successful_time` series before the first success — see [docs/forgejo-backups.md](forgejo-backups.md). `forgejo-backup-job-stale` applies the same creation-timestamp anchoring at a 2-day threshold and is the persistent counterpart to the edge-triggered, `topk(1)`-scoped `forgejo-backup-job-failed`, covering the case where no Job is produced at all.

**Continuous-readiness window (containerd-gc-storage and config-backup)**: `containerd-gc-storage-job-failed` and `config-backup-job-failed` use `min_over_time((max by (node) (kube_node_status_condition{node="k3s-nas", condition="Ready", status="true"}))[26h:1m]) == 1` — a 26-hour window that exceeds their 24-hour backup interval — rather than an instantaneous check. This ensures at least one full scheduled run has elapsed while the node was continuously healthy before a stale failed-job metric can trigger the alert. When the NAS returns after an offline period, the guard remains `false` for up to 26 hours, suppressing spurious alerts from jobs that failed during the downtime. Once the window elapses and a fresh successful run clears the stale metric, the guard becomes irrelevant; if a genuine failure occurs with the node continuously Ready for 26h, the alert fires correctly. The `for: 5m` debounce adds extra protection against flapping during node-Ready transitions. The Immich backup rule used to mirror this approach with a 7-hour window, but that guard suppressed genuine failures (see above) and was replaced with the `reason!="DeadlineExceeded"` filter instead. `config-backup-players-job-failed` deliberately does not join this family — its 02:05 schedule on the always-on node makes a 26-hour continuous-Ready requirement essentially unsatisfiable, so it uses the `reason!="DeadlineExceeded"` filter instead, same as Immich.

The guard must aggregate with `max by (node)` inside a subquery (`[26h:1m]`) rather than apply `min_over_time` directly to the bare selector, because `min_over_time` operates per time series, not per node. When kube-state-metrics restarts with a new pod IP, the `instance` label on `kube_node_status_condition` changes, so Prometheus starts a brand-new series while the old one goes stale — but the old series' last-known value is still visible inside the 26-hour lookback window and satisfied `== 1` for up to 26 hours after the pod that produced it was gone. On 2026-08-11, this let a `k3s-nas` outage that started at 02:05Z produce a spurious `Config Backup Job Failed` alert (issue #793) even though the guard should have suppressed it. Wrapping the selector in `max by (node) (...)` collapses all concurrent series for the node into one before the subquery samples it, so a dead series (which goes stale after ~5 minutes with no new scrapes) can no longer prop the guard up. Any future `_over_time` guard built on kube-state-metrics series needs the same treatment.

**"Running Too Long" alert** (`uid: immich-db-backup-duration-exceeded`): This alert fires when an active Immich DB backup job has been running for more than 10 minutes (`time() - kube_job_status_start_time > 600`, joined with `kube_job_status_active > 0`), gated by the k3s-nas readiness guard (`and on() kube_node_status_condition{node="k3s-nas", ...} == 1`). It uses `noDataState: OK` so silence between runs does not generate synthetic alerts. The k3s-nas guard prevents false positives when the NAS is offline and the pod is simply waiting for the NFS PVC mount (up to `activeDeadlineSeconds: 1800`, 30 minutes). The `pg_dump` process itself has no internal timeout — a hung dump keeps this alert firing (`for: 0s`) until the job's own `activeDeadlineSeconds: 1800` (30 minutes) kills it, so the alert can stay active for up to 20 minutes past its own 10-minute threshold. Routing is handled by the `.*Running Too Long` pattern in the CronJob alert receiver matcher.

**`uncovered-job-failed`** (appended to this group so it inherits the `Slack - CronJobs` route's `.*Job.*` matcher) watches the newest Job of every CronJob owner *except* the ones already covered above — `immich-db-backup`, `containerd-gc`, `containerd-gc-storage`, `forgejo-backup`, `forgejo-backup-offsite` (deliberately stale-only), `config-backup`, `config-backup-players`, `postgres-db-backup`, `downloads-janitor`, `pages-janitor`, `unifi-backup`, `datasette-sync-sqlite` — plus any other Job not owned by a CronJob, other than `migration-runner`. Today that means `renovate`, `datasette-sync`, `admission-error-reaper`, and `tofu-provider-mirror-*` for the CronJob-owned half; nothing currently matches the second half, but it is deliberately broad (`unless on (namespace, job_name) kube_job_owner{owner_kind="CronJob"}`, not `owner_kind="<none>"`) so it also catches a Job owned by some future non-CronJob controller, not only a truly ownerless one. The CronJob-owned half uses the newest-Job-per-CronJob `topk` idiom, so a later successful run clears the failed series and the alert self-resolves; **the non-CronJob-owned half has no such idiom, so an alert from it only clears once the failed Job object itself is deleted or its `ttlSecondsAfterFinished` expires**. No `DeadlineExceeded` exclusion is applied — none of these CronJobs mount NFS (`datasette-sync-sqlite` does, which is why it has its own rule with that exclusion), so a `DeadlineExceeded` here is not an expected NAS-sleep artifact. **Adding a rule for a new CronJob owner (a `*-job-failed` rule) must add that owner's name to this rule's exclusion regex too**, or the new dedicated rule and this catch-all will both fire on the same failure.

### Node Health Alerts

Alert rules fire on node-level disk conditions that precede kubelet DiskPressure eviction:

| Rule | Condition | Threshold | Severity |
|------|-----------|-----------|----------|
| Node Disk Pressure | `kube_node_status_condition{condition="DiskPressure"} == 1` | 5m pending | critical |
| Node Filesystem Almost Full | root filesystem < 15% free | 10m pending | warning |
| Node Filesystem Critical | root filesystem < 5% free | 2m pending | critical |

These alerts fire to Slack and create GitHub Issues. They provide early warning before pods start cycling on k3s-nas. The node-exporter DaemonSet is pinned to `system-node-critical` priority so it survives kubelet eviction during a DiskPressure incident, keeping Prometheus metrics flowing. See [docs/nas-k3s.md](nas-k3s.md#diskpressure-recovery) for the recovery runbook.

### Workload Health Alerts

Claws' built-in Kubernetes monitor (`k3s-monitor`, filing `[k3s] Workload failing: <ns>/<pod>` issues) was removed on 2026-09-22 (claws#3250/#3268). These Grafana rules (folder `Alerts`, group `Workload Health`, `interval: 1m`) replace that coverage for pod- and controller-level failure classes that kube-prometheus-stack's default `Kube*` PrometheusRules evaluate but never notify on, since Alertmanager is disabled and Grafana unified alerting does not read Prometheus-evaluated alerts.

| Rule | Condition | Pending | Severity |
|------|-----------|---------|----------|
| Workload Crash Looping | a container in `CrashLoopBackOff` | 10m | warning |
| Workload Container Waiting | a container in `ImagePullBackOff`/`ErrImagePull`/`InvalidImageName`/`CreateContainerConfigError`/`CreateContainerError` | 15m | warning |
| Workload OOM Killed | a container's last termination reason is `OOMKilled` and it has restarted in the last hour | 0m | warning |
| Workload Pod Not Ready | a `Running` pod (not Job-owned) fails its readiness condition | 15m | warning |
| Workload Pod Pending | a pod is stuck `Pending`/`Unknown` | 15m | warning |
| Workload Deployment Replicas Mismatch | available replicas below desired, with no rollout in progress | 15m | warning |
| Workload StatefulSet Replicas Mismatch | ready replicas differ from desired, with no rollout in progress | 15m | warning |
| Workload Rollout Stalled | a Deployment's `Progressing` condition is `false` | 15m | warning |

**Node-sleep guard**: `ryzen` and `k3s-nas` power down for most of the day by design (see "Node offline alert suppression" below), so the pod-level rules that carry a `node` label (crash-loop, container-waiting, pod-not-ready) join the pod to its node via `kube_pod_info` and drop it with `unless on (node) (max by (node) (kube_node_status_condition{condition="Ready", status="true"}) == 0)`. The `max by (node)` wrapper is mandatory — see the stale-`instance`-label gotcha under "Continuous-readiness window" below; the same failure mode applies to any `_over_time`/join guard built on kube-state-metrics series.

**Unscheduled Pending pods carry no node label**, so that guard cannot protect them. `Workload Pod Pending` applies the same `kube_pod_info` join and node-Ready guard first (it covers a pod that was bound to `ryzen`/`k3s-nas` just before the node slept, or a DaemonSet pod created for a NotReady node; an unscheduled pod has `node=""`, which matches no node and passes straight through). It, `Workload Deployment Replicas Mismatch` and `Workload Rollout Stalled` all then exclude the Deployments verified (from 7 days of Prometheus history) to produce a Pending replacement pod for the whole daily downtime of their node — `bazarr`, `immich`, `radarr`, `sonarr`, `transmission`, `forgejo-runner-nas` on `k3s-nas`; `ollama`, `whisper`, `forgejo-runner-ryzen` on `ryzen` — **but only while that node is not Ready**, via `unless on (...) (<per-node owner regex> and on () (max by (node) (kube_node_status_condition{node="<node>", condition="Ready", status="true"}) == 0))`. A permanent exclusion would also have hidden a real failure while the node was awake (sonarr stuck on an unbound PVC with the NAS up, ollama short of replicas with `ryzen` up), so the sleep list is gated on the node's actual state instead. `Workload Rollout Stalled` needs the same guard even though 7 days of history showed no sleeping Deployment tripping `Progressing=false`: that history covered sleep windows with no rollout in progress, and the Deployment controller only evaluates `progressDeadlineSeconds` while a rollout is actually running, so an image bump merged while a node-pinned Deployment's node is asleep would otherwise stall past the deadline and page. **A new node-pinned Deployment must be added to the matching per-node regex in all three rules**, or its sleep window will page. `Workload StatefulSet Replicas Mismatch` needs no such exclusion — no StatefulSet in this cluster is node-pinned.

**Failed-phase pods are deliberately not alerted on.** They are tombstones already replaced by their controller — the `UnexpectedAdmissionError` GPU boot race on `ryzen` is reaped by `admission-error-reaper` (see [gpu-k3s.md](gpu-k3s.md)) — so `Workload Pod Pending` matches only `Pending|Unknown`, and `Workload Pod Not Ready` matches only `phase="Running"`.

**One broken pod, one GitHub issue.** `Workload Pod Pending` and `Workload Pod Not Ready` would otherwise overlap with the more specific container-state rules: an `ImagePullBackOff`/`CreateContainerConfigError` container leaves its pod `Pending`, and a `CrashLoopBackOff` container leaves its pod `Running` but not Ready. Both rules add `unless on (namespace, pod) max by (namespace, pod) (kube_pod_container_status_waiting_reason{reason=~"..."})` — `Pod Pending` excludes the `Workload Container Waiting` reasons (its own phase can't overlap `Workload Crash Looping`, which requires `Running`), and `Pod Not Ready` excludes both `Workload Crash Looping` and `Workload Container Waiting` reasons — so the more specific rule wins and only one GitHub issue opens per broken pod. `Workload Deployment Replicas Mismatch` can still fire alongside either one; that overlap is left alone since it carries different, Deployment-level information (a replica shortfall) rather than duplicating the pod-level cause.

**OOM window**: `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}` sticks at its last value until the container's next restart, so `Workload OOM Killed` ANDs it with `increase(kube_pod_container_status_restarts_total[1h]) > 0`. It fires for about an hour after each OOM kill and self-resolves; a repeated OOM keeps the GitHub issue open.

**Controller-level rules are aggregated, not bare selectors.** `Workload Deployment Replicas Mismatch`, `Workload StatefulSet Replicas Mismatch` and `Workload Rollout Stalled` all wrap every side of their expression in `max by (namespace, deployment)`/`max by (namespace, statefulset)`, the same treatment the stale-`instance`-label gotcha under "Continuous-readiness window" above requires for any `_over_time`/join guard built on kube-state-metrics series. Without it, replacing the kube-state-metrics pod (chart bump, node drain) changes the `instance`/`pod` labels these series carry, so Grafana sees the old label set's series go stale and a new one start — which resets the `for: 15m` timer and fires a duplicate Slack/GitHub-issue notification for one still-ongoing mismatch or stall.

**Slack routing**: a new `Slack - Workloads` contact point (receiver uid `slack-workload-alerts`) and a route matching `^Workload.*`, grouped by `alertname` and `namespace`, `30s`/`5m`/`4h` like the other Slack routes — see the Contact Points and Notification Routing Policy tables below.

The `CronJob Monitoring` group also gained `Uncovered Job Failed` — see the CronJob Alerts table above for that rule.

### Servarr Alerts

Group `Servarr Health` (folder `Alerts`, `interval: 1m`), driven by the Sonarr/Radarr reconciler sidecar metrics above. Both rules use `noDataState: OK` and `execErrState: Error`: while the NAS sleeps the scrape targets are down and the series are absent, so nothing fires and the NAS is never woken.

| Rule | Condition | Pending | Severity |
|------|-----------|---------|----------|
| Servarr Import Blocked | `max by (app, download_id, title, reason) (servarr_queue_import_blocked_seconds) > 0`: a queue item is import-blocked/import-pending or completed with a warning. The gauge is 0 on the loop that first sees the item and turns positive one loop (5 min) later, so 10m pending fires about 15 minutes after the item was first seen | 10m | warning |
| Servarr Request Unavailable | `max by (app, title, rejections) (servarr_request_stalled{reason="no_acceptable_release"})`: an approved Seerr/Overseerr request is past the grace period and the daily release search found nothing acceptable | 30m | warning |

The summary and description name the app, the title and Sonarr/Radarr's status message (import-blocked) or the top three release rejection reasons without counts (request unavailable; counts would change the `rejections` label, and so the alert identity, on every daily search), so the GitHub issue body is actionable on its own. The unambiguous "matched to series/movie by ID" import case is auto-imported by the sidecar, normally before the 15 minutes pass. Anything else needs Interactive Import or removing the download. For an unavailable request, change the quality profile or decline the request.

Firing alerts resolve when the NAS goes to sleep (the series vanish) and fire again 15m/30m after it wakes if the condition persists. The GitHub bridge keeps one consolidated issue per alertname, so this produces resolve/re-fire comments rather than new issues.

**Slack routing**: contact point `Slack - Servarr` (receiver uid `slack-servarr-alerts`) and a route matching `^Servarr (Import|Request).*`, placed after the `Slack - CronJobs` route and grouped by `alertname`, `30s`/`5m`/`4h`. The `GitHub Issues` route matches first with `continue: true`.

### Cluster DNS

CoreDNS's `forward` plugin snapshots `/etc/resolv.conf` once at pod start. On 2026-08-15 21:17 UTC the `k3s` node's NetworkManager-managed resolv.conf changed underneath a 6-day-old CoreDNS pod, leaving it forwarding to a dead upstream; every external lookup returned SERVFAIL for ~35h (until a manual `kubectl rollout restart deployment coredns -n kube-system` at 2026-08-17 09:16 UTC) with nothing watching, breaking every Flux `HelmRepository` and several NAS-dependent backup CronJobs. See [docs/infrastructure-overview.md](infrastructure-overview.md) for the incident history — this is the second CoreDNS-upstream failure in three days from the same root cause (the node's mutable resolv.conf).

Two Grafana rules (folder `Alerts`, group `Cluster DNS`) now watch CoreDNS's own metrics: `CoreDNS SERVFAIL Rate High` and `CoreDNS Upstream Unreachable` (see table above). Both route to the `Slack - DNS` contact point via the `^CoreDNS.*` matcher, same as every other Slack-routed alert family in this stack.

The fastest signal is the Gatus `Cluster DNS` endpoint (`apps/gatus/config.yaml`), which queries `10.43.0.10` (CoreDNS's ClusterIP) directly for `github.com` every 60s — with `failure-threshold: 3` it turns red roughly 3 minutes into an outage, well before the 5–10 minute Grafana `for:` windows elapse.

**During a *total* external-DNS outage, neither Slack nor the GitHub-issues webhook can deliver until DNS recovers** — both need to resolve an external hostname through the very resolver that's broken. Grafana's Alertmanager retries on `group_interval`/`repeat_interval`, so the notification lands once CoreDNS is fixed, but it will read as "resolved" rather than "firing" if the fix happens first. The one signal that stays live throughout is the Gatus dashboard itself: a browser reaches it via the router's DNS, not CoreDNS, so it goes red immediately and stays visible for the duration of the outage.

### Authentik Worker Alerts

| Rule | Condition | Pending | Severity |
|------|-----------|---------|----------|
| Authentik Worker Database Errors | `sum(increase(django_db_errors_total{job="authentik-worker"}[15m])) > 10` | 10m | critical |
| Authentik Worker Task Errors | `sum(increase(authentik_tasks_errors_total{job="authentik-worker"}[1h])) > 5` | 15m | warning |
| Authentik Worker Metrics Target Down | `absent(up{job="authentik-worker"} == 1)` | 15m | warning |

During the 2026-08-25/26 NAS outage, a PostgreSQL pod restart left `authentik-worker` holding dead DB connections. `ak healthcheck` only checks the worker's PID file, so the pod stayed `Ready` for ~15h while every background task — including blueprint application — silently failed, and nothing alerted (#936). `django_db_errors_total` increments on every failed reconnect attempt; a sustained rate above the noise floor is now the fastest signal that the worker is wedged. `authentik_tasks_errors_total` catches the broader case of tasks failing for reasons other than a dead DB connection. All three rules route to the `Slack - Authentik` contact point via the `^Authentik.*` matcher, same pattern as every other Slack-routed alert family in this stack.

### Postgres Connection Alerts

| Rule | Condition | Pending | Severity |
|------|-----------|---------|----------|
| Postgres Connection Saturation | `sum(pg_stat_activity_count) / max(pg_settings_max_connections) * 100 > 70` | 10m | warning |
| Authentik Postgres Connections Near Role Cap | `sum(pg_stat_activity_count{usename="authentik"}) > 90` | 2m | warning |
| Postgres Exporter Target Down | `absent(up{job="postgres-exporter"} == 1)` | 15m | warning |

On 2026-09-09 the shared instance ran out of connection slots for ~2.5 minutes and refused
every non-superuser client with `remaining connection slots are reserved for roles with the
SUPERUSER attribute`, taking out Authentik SSO and Forgejo together; because `log_connections`
was off and nothing exported `pg_stat_activity`, the role holding the slots was never
identified (#1235). The 70% threshold on `max_connections` (200) is deliberately well below
the cliff — by the time clients are being refused the outage has already happened. When it
fires, find the holder with
`topk(5, sum by (usename, datname, state) (pg_stat_activity_count))` and adjust that role's cap
in `migrations/0031-postgres-connection-limits.sh`, which is repeatable and re-applies on the
next Flux reconcile. `Postgres Exporter Target Down` exists because a dead exporter makes the saturation rule read
as healthy rather than unknown. It uses `noDataState: OK`, not `Alerting`: `absent()` already
returns `1` when the target is down or gone, so NoData is the *healthy* branch. It shipped
with `noDataState: Alerting` and consequently fired 15 minutes after every Grafana restart with
`up{job="postgres-exporter"}` unbroken at 1 — #1244 and #1260, both false positives, the second
timed exactly 15m23s after the Grafana pod rolled for the #1259 values change.

The instance-wide 70% rule cannot see a single role hitting its own `rolconnlimit`, which
fails as `too many connections for role "authentik"` and takes SSO down without the instance
ever approaching saturation — hence a per-role rule for the one tenant whose cap is close to
its peak (#1245). Its threshold is 90 of the role's 110-connection cap; both were raised from
45/60 after the cap proved to be below Authentik's boot demand and turned the routine rollout
of #1252 into an eleven-minute SSO outage (#1256).

### Flux Reconciliation Alerts

| Rule | Condition | Pending | Severity |
|------|-----------|---------|----------|
| Flux Kustomization Not Ready | `max by (exported_namespace, name) (gotk_resource_info{customresource_kind="Kustomization", ready="False", suspended!="true"})` | 15m | critical |
| Flux HelmRelease Not Ready | `max by (exported_namespace, name) (gotk_resource_info{customresource_kind="HelmRelease", ready="False", suspended!="true"})` | 30m | critical |

These replace the Flux half of the removed Claws `k3s-monitor`, which used to file
`[k3s] Flux Kustomization NotReady: …` / `[k3s] Flux HelmRelease NotReady: …` issues from
outside the cluster. They cover **every** Kustomization and HelmRelease in the cluster, not
just the ten objects enumerated in the `slack-errors` Flux `Alert` (see
[notifications.md](notifications.md)) — `gotk_resource_info` is emitted per-object by
kube-state-metrics custom resource state (see [flux controllers](#flux-controllers) above),
so a `HelmRelease` like `loki` or `authentik` that stays `Ready=False` now files a GitHub
issue even though it was never added to `slack-errors`.

Both rules use `noDataState: OK`: the query filters to `ready="False"`, so an object with no
matching series (healthy, or gone) is the healthy branch — the same `absent()`-family
reasoning as `kube-state-metrics-down` and the Postgres target-down rule above, though here it
falls out of the label filter rather than an explicit `absent()` call. `suspended!="true"`
excludes suspended objects. `gotk_resource_info` is an info metric, so a readiness flip
creates a new series and lets the old one go stale — `max by (exported_namespace, name)`
collapses that safely for an instant query; do not wrap this expression in a range function.

The pending periods are chosen to ride out the transient `kube-prometheus-stack` upgrade
window: `for: 15m` on the Kustomization rule and `for: 30m` on the HelmRelease rule, both
exceeding the 20m `upgrade.timeout` on `kube-prometheus-stack` — see
[kube-prometheus-stack (HelmRelease)](#kube-prometheus-stack-helmrelease), "No Helm wait".
With `disableWait: true` a normal upgrade now settles in seconds, so 30m of continuous
`Ready=False` is a genuine problem, not upgrade noise. A `HelmRelease` with
`Ready=Unknown` while progressing does not match `ready="False"` and does not fire; a failed
upgrade sitting at `False` between `remediation.retries` attempts does fire after 30m, which
is the intended signal.

Routing follows the one-contact-point-per-family pattern: a `Slack - Flux` contact point and
an `alertname =~ "^Flux.*"` route (see [Contact Points](#contact-points) and
[Notification Routing Policy](#notification-routing-policy) below). GitHub issue filing needs
no separate routing change — the `GitHub Issues` route is a catch-all with `continue: true`
that every alert not otherwise excluded already reaches.

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
- Loki: 10 GB, 7-day retention (not expandable — see docs/logging.md)

**Note on cascading failure**: If Prometheus fills its PVC and crash-loops, Grafana alerting cannot evaluate queries against it, so the alert cannot fire. The 80% warning threshold provides early warning well before this failure mode. A truly resilient solution would require an external watchdog beyond the scope of this stack.

### Memory pressure and swap alerts

The Grafana-managed `Node Pressure` rules also watch memory pressure across the
k3s nodes and the Proxmox host (the latter is scraped by `proxmox-node-exporter`):

| Rule | Condition | Pending | Severity |
|------|-----------|---------|----------|
| Node Memory Available Low | < 10% of physical memory available (k3s nodes only; excludes `instance="proxmox"`) | 15m | warning |
| Proxmox Host Memory Headroom Low | < 1 GiB MemAvailable | 15m | warning |
| Node Swap Thrashing | > 100 swap-in/out pages per second | 15m | critical |

`Node Memory Available Low` uses a percentage-of-total threshold, which fits
the k3s nodes but not the Proxmox hypervisor: the host commits 24 GiB (k3s VM)
+ 4 GiB (haos VM) of its 33 GB to VMs, so its own MemAvailable baseline runs
9-14% (21-day daily minima 7.4-9.8%, floor 2.44 GB) purely from that
allocation, not from workload pressure. That made the percentage rule flap and
filed eleven `[Alert] Node Memory Available Low` GitHub issues between
2026-09-19 and 2026-09-23. `Node Memory Available Low` now excludes
`instance="proxmox"`, and `Proxmox Host Memory Headroom Low` covers the
hypervisor instead with an absolute 1 GiB threshold, well below the observed
floor so it cannot flap on cache noise. `Node Swap Thrashing` (critical)
remains the backstop for actual host paging. The new rule's title matches the
`Proxmox.*` Slack routing matcher, so it also posts to the Proxmox Slack
contact point in addition to the normal GitHub occurrence-tracking bridge.

These are deliberately sustained thresholds. A short burst can be absorbed by
the kernel cache and does not need an alert; persistent swap activity means the
host is paging its working set and workloads should be investigated before
raising pod or VM limits. The alerts route to the Node Slack contact point and
the normal GitHub occurrence-tracking bridge.

The Claws pod has a 10 GiB memory limit and currently has no cgroup swap
allowance, sized to hold two concurrent 4 GiB worker watchdogs plus service
overhead (see [apps-overview.md](apps-overview.md#claws)); the Proxmox swap
device is only a last-resort host safety net, not worker capacity.

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

Grafana routes alerts via ten contact points. All Slack contact points share the `grafana-slack-webhook` Kubernetes secret (key: `webhook-url`), injected as `SLACK_WEBHOOK_URL` via `envValueFrom` and referenced in `settings.url` as `$__env{SLACK_WEBHOOK_URL}`. The `optional: true` flag prevents Grafana from crashing if the secret is absent.

| Contact Point | Mechanism | Purpose |
|--------------|-----------|---------|
| `Slack - PVC` | Slack webhook | PVC capacity alerts |
| `Slack - CronJobs` | Slack webhook | CronJob failure/schedule alerts |
| `Slack - Node` | Slack webhook | Node health alerts (`alertname =~ "Node.*"`) |
| `Slack - Proxmox` | Slack webhook | Proxmox hardware alerts (`alertname =~ "Proxmox.*"`) |
| `Slack - DNS` | Slack webhook | CoreDNS alerts (`alertname =~ "^CoreDNS.*"`) |
| `Slack - Authentik` | Slack webhook | Authentik worker alerts (`alertname =~ "^Authentik.*"`) |
| `Slack - Flux` | Slack webhook | Flux reconciliation alerts (`alertname =~ "^Flux.*"`) |
| `Slack - Workloads` | Slack webhook | Workload health alerts (`alertname =~ "^Workload.*"`) |
| `Slack - Servarr` | Slack webhook | Servarr import/request alerts (`alertname =~ "^Servarr (Import\|Request).*"`) |
| `GitHub Issues` | `grafana-github-alerts` webhook | Maintains one consolidated GitHub issue per incident (one section per alertname) |

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
| Slack - Servarr | `alertname =~ "^Servarr (Import\|Request).*"` | `alertname` | 4h | no |
| Slack - DNS | `alertname =~ "^CoreDNS.*"` | `alertname` | 4h | no |
| Slack - Authentik | `alertname =~ "^Authentik.*"` | `alertname` | 4h | no |
| Slack - Flux | `alertname =~ "^Flux.*"` | `alertname` | 4h | no |
| Slack - Workloads | `alertname =~ "^Workload.*"` | `alertname`, `namespace` | 4h | no |

**Node offline alert suppression** (`ryzen` and `k3s-nas` nodes): The GPU worker (`ryzen`, 192.168.0.69) and NAS worker (`k3s-nas`) go offline regularly in normal homelab operation. Three built-in chart alerts fire when a node is unreachable — `KubeNodeNotReady`, `KubeNodeUnreachable`, and `KubeletDown` — creating noisy GitHub issues for expected transient outages. Suppression is applied at two levels:

1. **PrometheusRule level**: The three alerts are disabled via `defaultRules.disabled` and replaced with custom rules in `additionalPrometheusRulesMap` that exclude `ryzen` and `k3s-nas` from the expression (`node!~"ryzen|k3s-nas"`). These alerts never enter the alerting system for those two nodes. The custom `KubeletDown` rule uses `up{job="kubelet", metrics_path="/metrics", node!~"ryzen|k3s-nas"} == 0` (not `absent()`) so the `node` label is preserved for the exclusion filter.

2. **Routing level** (belt-and-suspenders): The `GitHub Issues` route has `object_matchers: [["alertname", "!~", "KubeNodeNotReady|KubeNodeUnreachable|KubeletDown"]]`, preventing any leakage (e.g., during alertmanager config reload lag) from creating GitHub issues.

Pod- and container-level rules (`Workload Crash Looping`, `Workload Container Waiting`, `Workload Pod Not Ready`) use the same node-sleep exclusion at the query level, joining the pod to its node's `kube_node_status_condition` and dropping it while the node is not Ready — see "Workload Health Alerts" above for the exact guard and its `Workload Pod Pending`/`Workload Deployment Replicas Mismatch` counterpart for pods that have no node label yet.

Disk/filesystem node alerts (`NodeDiskPressure`, `NodeFilesystemAlmostFull`, `NodeFilesystemCritical`) are NOT suppressed — they still create GitHub Issues and Slack notifications.

The `continue: true` on the `GitHub Issues` route means any alert not in the exclusion list goes to GitHub **and** continues evaluation to the appropriate Slack route. All PVC, CronJob, and node disk/filesystem alerts therefore create GitHub Issues in addition to Slack notifications.

GitHub Issues group wait is 1m; all Slack routes use 30s group wait.

**Known standing conditions**: The `GitHub Issues` route matches on `alertname` only and carries no severity filter, so *any* new alert rule files a GitHub issue by default. A condition that is known, permanent, and only resolvable by manual work must therefore be given a terminal route (no `continue: true`) placed **before** the `GitHub Issues` route, which stops evaluation and keeps the alert Slack-only and visible in the Grafana UI. The `Immich Database Is Empty` route (see table above) is the first example of this idiom — reuse it for future known conditions rather than adding exclusion regexes to `GitHub Issues` or a severity filter to the alert rule.

### Grafana GitHub Alerts

`apps/monitoring/grafana-github-alerts/` is an in-cluster Python webhook receiver that bridges Grafana alert firings to GitHub issues on the `St-John-Software/fleet-infra` repository. Its `server.py`/`test_server.py` are a byte-for-byte copy of the shared `alert-issue-bridge` script that production-infra runs for its own Alertmanager (`infrastructure/prod/observability/alert-issue-bridge/`, St-John-Software/production-infra#1698); production-infra's copy is canonical, so make script edits there first and copy them here. The two repos were meant to converge on one shared GHCR image (St-John-Software/production-infra#1693), but that route was dropped because the org keeps GHCR packages private and a private image at the root of production-infra's `wait: true` Flux DAG was judged too risky — each repo keeps its own copy of the script instead, driven entirely by env vars so a shared image remains a drop-in swap later if that constraint changes.

**How it works**:
```
Alert webhook delivery (one payload, possibly several alerts)
  → POST to grafana-github-alerts:8080/webhook
  → group alerts by alertname (a group is firing if any instance is firing)
  → list open issues with label ALERT_LABEL, keep the one titled exactly ISSUE_TITLE
  → open issue found: add/update each alert's "### <alertname>" section
      firing   → status firing, Last occurrence = now, Occurrences + 1, track each
                 firing instance's fingerprint in the section
      resolved → drop the resolved instance's fingerprint; status resolved only
                 once no fingerprint remains for that section
    → close the issue once every section is resolved
  → no open issue, something firing:
      closed alert issue closed within REOPEN_WINDOW_HOURS → reopen it and update its sections
      otherwise → create a new issue (a new incident)
  → no open issue, only resolved alerts → ignore
```

Tracking firing instances per fingerprint (Alertmanager's `fingerprint`, falling back to a hash of the label set) means a resolve from one alertname/namespace group no longer masks another group of the same alertname that is still firing — each section only resolves once every one of its own firing instances has resolved.

The service uses Python stdlib only (`urllib`, `json`, `re`) — no pip installs or external dependencies. It runs as a non-root user with a read-only root filesystem. The script lives in `server.py` and is shipped by a hash-suffixed `configMapGenerator` (`grafana-github-alerts-script-<hash>`), so any edit to the script changes the ConfigMap name and rolls the pod on merge. `test_server.py` covers the issue-routing logic against a fake GitHub API and runs in the blocking `grafana-github-alerts-tests` CI job; run it locally with `nix develop --command python3 -m unittest discover -s apps/monitoring/grafana-github-alerts -p 'test_*.py' -v`.

**Secret** (imperative, never in Git):
```bash
kubectl create secret generic grafana-github-token \
  --from-literal=token=<GITHUB_PAT> \
  -n default
```
The PAT must have `Issues: Read & Write` and `Metadata: Read` permissions. The key name must be exactly `token`.

**Webhook shared secret**: stored as a SOPS-encrypted Secret at `apps/monitoring/grafana-github-alerts/shared-secret.enc.yaml`, decrypted by Flux's `kustomize-controller` at reconcile time using the cluster age key in `flux-system/sops-age`. The shared secret authenticates Grafana's POST requests to the webhook receiver — both the Grafana pod and the webhook pod read `secretKeyRef.name: grafana-webhook-shared-secret` from `default`. To rotate: edit the file with `sops apps/monitoring/grafana-github-alerts/shared-secret.enc.yaml`, update the `token` value, commit, and push. After Flux reconciles, run `kubectl rollout restart deployment/grafana-github-alerts deployment/kube-prometheus-stack-grafana -n default` so both pods pick up the new token.

**NetworkPolicy**: `grafana-github-alerts-networkpolicy.yaml` restricts ingress to port 8080 on the webhook receiver to pods matching `app.kubernetes.io/name: grafana` and `app: gatus` (for the `/healthz` probe only; `POST /webhook` remains gated by the Bearer shared secret, which Gatus does not hold). This prevents other in-cluster workloads from calling the webhook directly (which would allow them to create or close GitHub issues using the webhook's `GITHUB_TOKEN`). The token is never exposed outside the cluster; the NetworkPolicy is defence-in-depth against cluster-internal abuse.

**Pod hardening**: the webhook pod sets `automountServiceAccountToken: false` — it never calls the Kubernetes API, and suppressing the `default` ServiceAccount token keeps a compromise of the hand-rolled `http.server` handler scoped to the GitHub PAT and shared secret rather than also yielding a cluster API credential. It also runs `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, and `allowPrivilegeEscalation: false`.

**Prometheus NetworkPolicy**: `prometheus-networkpolicy.yaml` restricts Prometheus's ingress on port 9090 to the `traefik` namespace, the Grafana datasource, and Gatus, plus a portless self-scrape rule so Prometheus can keep scraping its own pod (9090) and the `prometheus-config-reloader` sidecar (8080). Without it, unauthenticated in-cluster pods could query the full Prometheus API (all cluster metrics) directly on the ClusterIP, bypassing the ForwardAuth middleware on the ingress entirely.

**Deduplication**: every alert the bridge receives for `GITHUB_REPO` lands in a single open issue at a time, titled `ISSUE_TITLE` (default `[Alert] Grafana alerts firing`) and labelled `ALERT_LABEL` (default `grafana-alert`). Concurrent alerts are far more likely to share a root cause than not; split one out by hand if it genuinely needs separate tracking. The open issue is found with the REST issue list (`state=open&labels=<label>`), matching the title exactly and skipping pull requests — not the search API, whose index lag let one outage file four issues in the same minute (#782–#785). The body carries a "Currently firing" list, then one `### <alertname>` section per alert with severity, status, first/last occurrence, occurrence count, resolved time, optional source (`generatorURL`, shown when `INCLUDE_GENERATOR_URL` is `"true"` — set here since this bridge's `generatorURL` points at this cluster's own reachable Grafana, unlike production-infra's), summary and description. Resolved sections stay in the body for the life of the issue, so the incident history reads in one place. Flapping no longer forks issues: when an alert fires with no open alert issue but the last one was closed within `REOPEN_WINDOW_HOURS` (default 24), that issue is reopened and updated instead of a new one being filed — `[Alert] Node Memory Available Low` alone produced 13 issues in four days under the old one-issue-per-alertname scheme. To force a fresh issue for a genuinely new incident inside the window, remove the label from the closed issue. `GITHUB_REPO`, `ALERT_LABEL`, `ISSUE_TITLE`, `REOPEN_WINDOW_HOURS`, `INCLUDE_GENERATOR_URL` and `LISTEN_PORT` are all env vars on the Deployment, and only the fields Grafana and Alertmanager webhooks share (`labels`, `annotations`, `status`, `startsAt`, `endsAt`, `generatorURL`, `fingerprint`) are read, so the same script also serves production-infra's Alertmanager. The body is parsed back and fully re-rendered on every update; a hand-edited body that no longer parses is rebuilt from the current payload, keeping `First seen` and the running occurrence total.

**Note on token expiry**: Fine-grained PATs have an expiration date. If the token expires, the pod continues running but all GitHub API calls return 401. Failures are logged to stdout — monitor pod logs if alerts stop appearing as GitHub issues.

**Network-error handling**: `github_api()` catches `HTTPError`, `URLError`, `OSError` and `json.JSONDecodeError`, returning `None` — a GitHub outage degrades the receiver rather than crashing it. This matters at startup: `ensure_label_exists()` runs before the HTTP server binds, so an uncaught `URLError` there used to put the pod into CrashLoopBackOff until GitHub happened to be reachable on a restart. All GitHub calls use an explicit `timeout=30`. The server is a `ThreadingHTTPServer`, so `/healthz` never queues behind GitHub, but deliveries themselves serialise on a `DELIVERY_LOCK` so two concurrent webhook calls can't race a read-modify-write of the same issue body. Liveness is monitored by the `Grafana GitHub Alerts` Gatus endpoint (`http://grafana-github-alerts:8080/healthz`) — the pod is deliberately not in the Flux `healthChecks` list.

**Interaction with Claws' Refined workflow**: because the webhook closes the alert issue as soon as every alert in it resolves, a `Refined` plan sitting on that issue can be closed out from under Claws before it implements the fix — if the alerts clear on their own (flapping condition, node coming back up) between planning and implementation. If any alert re-fires within `REOPEN_WINDOW_HOURS`, the bridge reopens the issue itself; outside the window the issue must be reopened by hand before Claws will act on it again, and a reopen comment counts as new planner input and costs one extra refiner pass to re-confirm the plan, rather than resuming implementation immediately. The body ends with Claws' own occurrence block (`---`, `**First seen:** …`, `**Last seen:** …`, `**Occurrences:** N`, where N is the total firings across all sections); Claws strips it before hashing the body and uses N for its occurrence-based re-plan path, so it must stay the last three lines of the body and the bold `**Occurrences:**` form must not appear anywhere else in it.

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

The entire monitoring config is in `monitoring/kube-prometheus-stack.yaml` as HelmRelease values. Changes to Grafana settings, Prometheus retention, scrape configs, or feature toggles are all made in that single file. New alert rules must keep their `uid` at 40 characters or fewer — see the UID constraint under [Grafana Alerting](#grafana-alerting).

For new exporters, create a subdirectory under `monitoring/` with deployment + service manifests and add a corresponding `additionalScrapeConfigs` entry in the HelmRelease.
