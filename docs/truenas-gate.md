# TrueNAS Gate (NAS availability proxy)

The name is historical — the box hasn't run TrueNAS since the 2026-07-27 NixOS migration (see [nas-k3s.md](nas-k3s.md)) — but the directory, resources, and this filename are unchanged.

An nginx reverse proxy that provides graceful degradation for services that depend on the NAS's NFS storage. When a backend is unavailable, users see a "wake the NAS" page instead of raw errors.

## Problem

Several services depend on the NAS (192.168.0.128) for NFS storage. When the NAS is powered off or rebooting, these services become unavailable. Without the gate, users see confusing 502/503 errors.

## How It Works

```
User → Traefik Ingress → truenas-gate (nginx) → Backend Service
                              │
                              ├─ Backend UP:   proxy_pass to service
                              └─ Backend DOWN: serve wake page (502/503/504 → @gate)
```

1. Ingresses for gated services point to `truenas-gate:80` as the backend
2. Nginx routes by `Host` header to the appropriate upstream
3. If the upstream returns 502, 503, or 504 (or connection refused), nginx serves a static wake page
4. The wake page lets users trigger a Wake-on-LAN signal to the NAS via a Home Assistant webhook
5. The page auto-refreshes, redirecting to the service once it comes online

## Gated Services

Currently gated (defined as `upstream` blocks in `nginx-config.yaml`):

| Host | Upstream |
|------|----------|
| immich.home.bstjohn.net | immich:2283 |
| plex.home.bstjohn.net | plex:32400 |
| transmission.home.bstjohn.net | transmission:9091 |

Only these three services have their ingresses routing to `truenas-gate:80`. Other NFS-dependent services (sonarr, radarr) connect directly — they don't need the gate because their pods simply wait for NFS to become available.

Plex used to be a hand-written `Endpoints` object pointing at an external FreeBSD jail; it's now a real in-cluster Deployment (see [nas-k3s.md](nas-k3s.md)). The Service name/port (`plex:32400`) is unchanged, so the gate's config didn't need to change — but its *rationale* did, see below.

## The always-on wake page: `wake.home.bstjohn.net`

Since [#800](https://github.com/St-John-Software/fleet-infra/issues/800), **Plex and Jellyfin no longer reach the gate when the NAS sleeps.** They run on the always-on `k3s` node against a `soft` NFS mount, so their pods stay up and answer requests; nginx's `error_page 502 503 504 → @gate` never fires for them. Playback fails with `EIO` instead — which means the family lost the click-to-wake button at exactly the moment they need it.

The fix is a hostname of its own. A fourth `server` block matches `wake.home.bstjohn.net` and serves the wake page directly, with no upstream and no error condition:

```nginx
server {
    listen 80;
    server_name wake.home.bstjohn.net;
    location / {
        root /usr/share/nginx/html;
        try_files /index.html =503;
    }
}
```

`apps/truenas-gate/ingress.yaml` routes that host to `truenas-gate:80`. The gate itself runs on `k3s` with no NAS dependency, so the page is reachable whenever the cluster is — including while every gated service is healthy. It is also linked from Homepage as "Wake NAS".

The Plex `server` block above is kept regardless: the gate still covers the window where a Plex pod is *restarted* while the NAS is asleep, which leaves it in `ContainerCreating` (a soft mount rescues a running pod, not a starting one).

## Files

```
truenas-gate/
├── kustomization.yaml
├── deployment.yaml          # nginx:1.28.3-alpine, port 80
├── service.yaml             # ClusterIP
├── nginx-config.yaml        # ConfigMap: nginx.conf with upstream/server blocks
├── configmap.yaml           # ConfigMap: static HTML wake page
├── ingress.yaml             # wake.home.bstjohn.net → truenas-gate:80
├── wake-webhook-secret.enc.yaml   # SOPS Secret: nginx snippet with the HA webhook URL
└── README.md
```

## Configuration

### nginx-config.yaml

Defines upstream backends and server blocks. Each gated service gets:

```nginx
upstream servicename {
    server servicename:port;
}

server {
    listen 80;
    server_name servicename.home.bstjohn.net;
    error_page 502 503 504 =503 @gate;

    location / {
        proxy_pass http://servicename;
        proxy_intercept_errors on;
        # standard proxy headers...
    }

    location @gate {
        root /usr/share/nginx/html;
        try_files /index.html =503;
    }
}
```

**Timeouts**: `proxy_connect_timeout: 2s` (fast failure detection), `proxy_read_timeout: 30s`, `proxy_send_timeout: 30s`.

### Wake webhook

The wake page's "Wake the NAS" button POSTs same-origin to `/_gate/wake`. Nginx proxies that
to `http://home-assistant:8123/api/webhook/<id>`. The webhook ID is a bearer credential —
anyone who knows it can trigger the automation without authentication — so it lives only in
the SOPS-encrypted Secret `truenas-gate-wake-webhook`, mounted at
`/etc/nginx/wake/wake-webhook.conf` and `include`d by every server block. It is never embedded
in the client-served HTML/JS (this repo has a public mirror; anything committed there is
permanent and world-readable).

The snippet explicitly blanks `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Host`,
`X-Forwarded-Server`, and `X-Real-IP` before proxying. Home Assistant's `configuration.yaml`
sets `use_x_forwarded_for: true` with `trusted_proxies: [192.168.0.251]`, and returns HTTP 400
if a forwarded header arrives from any other peer. The pod egresses as the k3s node IP, not
`192.168.0.251`, so without blanking these headers every wake request would fail.

To rotate or inspect the webhook ID: `sops apps/truenas-gate/wake-webhook-secret.enc.yaml`,
then `kubectl rollout restart deployment/truenas-gate` — there is no config reloader.

### Adding a New Gated Service

1. Add an `upstream` block in `nginx-config.yaml` pointing to the service's ClusterIP
2. Add a `server` block with the service's hostname and the `@gate` error handler
3. Update the service's Ingress to use `truenas-gate:80` as the backend instead of the service directly
4. If the backend has a NetworkPolicy, add `truenas-gate` to its permitted ingress peers.
5. Add `include /etc/nginx/wake/wake-webhook.conf;` to the new server block, or the wake button 404s on that host.

### NetworkPolicy requirement

If the backend service has a `networkpolicy.yaml`, its ingress rule must include a
`podSelector` peer matching `app: truenas-gate` in the `default` namespace. Since the
gated service's Ingress routes to `truenas-gate:80` rather than the backend Service
directly, omitting this peer causes Traefik → gate → backend to be rejected at the
network layer, and the ingress serves the "The NAS is asleep" wake page permanently —
even when the backend and the NAS are both healthy. This exact regression happened in
[#771](https://github.com/St-John-Software/fleet-infra/issues/771), caused by
[#648](https://github.com/St-John-Software/fleet-infra/pull/648) narrowing
Transmission's NetworkPolicy without accounting for the gate. `scripts/check-gate-netpol.sh`
enforces this in CI (`task check-gate-netpol`).

### Resources

Minimal footprint: 5m CPU request, 16-64 MB memory. The gate is just an nginx proxy. Has liveness and readiness probes (httpGet `/` port 80).
