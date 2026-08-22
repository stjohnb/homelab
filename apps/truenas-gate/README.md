# TrueNAS Gate (NAS availability proxy — name is historical, see docs/nas-k3s.md)

An nginx reverse proxy that gates access to NAS-dependent services (Immich, Plex, Transmission). When backends are unavailable, users see a friendly wake-up page instead of error messages.

## How it works

1. All traffic for gated services (immich.home..., plex.home..., transmission.home...) routes through truenas-gate nginx

2. Nginx proxies requests to the appropriate backend based on Host header

3. If the backend is unreachable (connection refused, timeout), nginx serves the wake page instead

4. The wake page lets users:
   - Send a WoL wake signal to the NAS via a same-origin `/_gate/wake` request, which nginx proxies to the Home Assistant webhook
   - Wait with a progress bar while the NAS boots
   - Auto-refresh when the NAS comes online

The HA webhook ID is a bearer credential, so it is never embedded in the client-served page. It lives only in the SOPS-encrypted Secret `truenas-gate-wake-webhook` (`wake-webhook-secret.enc.yaml`), mounted into the nginx container and `include`d by every server block — see `docs/truenas-gate.md`.

## Components

- `nginx-config.yaml` - Nginx config with proxy rules and fallback
- `configmap.yaml` - Static HTML wake page
- `deployment.yaml` - nginx:alpine serving the proxy
- `service.yaml` - ClusterIP service on port 80
- `wake-webhook-secret.enc.yaml` - SOPS Secret: nginx snippet proxying `/_gate/wake` to the HA webhook

## Adding a new gated service

1. Add a new `server` block in `nginx-config.yaml` with the hostname and upstream
2. Update the service's Ingress to point to `truenas-gate:80` instead of the backend directly
3. If the backend Service's pods are covered by a NetworkPolicy, add a `podSelector` peer for `app: truenas-gate` — otherwise the gate is rejected and the wake page shows permanently (see #771)

## No sidecars needed

Unlike the previous approach with init containers and health-check sidecars, the gate handles availability detection dynamically per-request. Backend deployments stay clean.
