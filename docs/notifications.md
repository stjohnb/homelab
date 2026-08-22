# Flux Notifications

Configuration: `clusters/my-cluster/flux-system/notifications.yaml`

## Providers

### Slack

- **Type**: Slack
- **Channel**: `lab`
- **Secret**: `flux-slack-webhook` in `flux-system` namespace (contains the Slack incoming webhook URL)

### Grafana

- **Type**: Grafana
- **Address**: `http://kube-prometheus-stack-grafana.default.svc/api/annotations` (internal cluster DNS, bypasses ingress/Authentik)
- **Secret**: `grafana-annotations-token` in `flux-system` namespace (contains a Grafana service account token with Editor role)

## Alerts

### `slack-errors` (error severity)

Fires when any reconciliation fails.

**Watched Kustomizations:**
- `flux-system` — root reconciliation
- `infrastructure` — cert-manager, traefik, godaddy-webhook
- `config` — certificates, RBAC
- `apps` — application services
- `migrations` — secret-generation Jobs (`./migrations`)

A Kustomization build or apply error on `./migrations` posts to Slack. A *migration script* that fails does not — the Kustomization still reports Ready because the Job object applies fine. That case is covered by the `Migration Runner Job Failed` Grafana rule; see [monitoring.md](monitoring.md#cronjob-alerts).

**Watched HelmReleases:**
- `cert-manager` (flux-system)
- `godaddy-webhook` (flux-system)
- `headlamp` (default)
- `traefik` (flux-system)
- `kube-prometheus-stack` (default)

**Summary text**: "Flux apply failed"

### `grafana-annotations` (info severity, filtered)

Posts annotation markers to Grafana on deployment events, enabling visual correlation
between deployments and metric changes on any dashboard panel.

**Watched Kustomizations:**
- `flux-system` — root reconciliation
- `infrastructure` — cert-manager, traefik, godaddy-webhook
- `config` — certificates, RBAC
- `apps` — application services
- `migrations` — secret-generation Jobs (`./migrations`)

**Watched HelmReleases:**
- `cert-manager` (flux-system)
- `godaddy-webhook` (flux-system)
- `headlamp` (default)
- `traefik` (flux-system)
- `kube-prometheus-stack` (default)

**Filters** (`inclusionList`):
- `^Helm upgrade succeeded` / `^Helm install succeeded` — Helm chart deployments
- `^Applied revision` — Kustomization applied a new Git revision
- `^Reconciliation finished` — successful reconciliation completion

**Summary text**: "Flux deployment"

**Note**: If `Reconciliation finished` generates noise from steady-state HelmRelease
no-op reconciliations, remove it from the `inclusionList`.

## Grafana Annotations Setup

### Prerequisites: Create the API token secret

1. Log into Grafana as admin
2. Go to **Administration > Service accounts > Create service account**
   - Name: `flux-annotations`
   - Role: `Editor`
3. Generate a token for the service account
4. Create the Kubernetes secret:
   ```bash
   kubectl create secret generic grafana-annotations-token \
     --from-literal=token=<grafana-service-account-token> \
     -n flux-system
   ```

### Viewing annotations on dashboards

After the Provider and Alert are reconciled by Flux, annotations are posted automatically.
To display them on a dashboard:

1. Open the dashboard in Grafana
2. Go to **Settings > Annotations > Add annotation query**
3. Data source: `-- Grafana --`
4. Filter by Tags: `flux`
5. Save — vertical markers will appear on all panels at deployment timestamps

## Design Decisions

The notification setup is intentionally low-noise and centralized:
- **Single location**: All alerts are defined in `clusters/my-cluster/flux-system/notifications.yaml`. There are no app-level notification resources — a previous `apps/flux-notifications/` directory with a catch-all wildcard alert was removed because it fired on every reconciliation event, producing repeated noise every ~5 minutes.
- **Failures only on Slack**: every Slack alert is `eventSeverity: error`. Successful deploys (Kustomization applies, Helm upgrades, source revision changes) are recorded as Grafana annotations instead — see the `grafana-annotations` Alert.
- **Cross-namespace support**: The alerts in `flux-system` can watch resources in other namespaces (e.g., `kube-prometheus-stack` in `default`) via the `namespace` field in `eventSources`.
- Error alerts cover all managed resources to ensure failures are visible

## Adding Watched Resources

To monitor a new HelmRelease or Kustomization for errors, add an entry to the `slack-errors` Alert's `eventSources` list:

```yaml
- kind: HelmRelease          # or Kustomization
  name: my-new-release
  namespace: flux-system      # namespace where the resource is defined
```
