# fleet-infra

Selected GitOps configuration from a three-node k3s homelab cluster, managed by Flux CD. All changes land on `main` via Pull Request; Flux automatically reconciles the cluster within about a minute. The manifests here are specific to the author's hardware, DNS zone, and NAS, so this repo is a reference rather than a deployable template.

## What is here

- `clusters/my-cluster/` — the root `kustomization.yaml`, the four core layer Kustomizations (`infrastructure`, `config`, `migrations`, `apps`), and `flux-system/gotk-sync.yaml`
- `clusters/my-cluster/infrastructure/` — the layer's `kustomization.yaml`, plus `cert-manager/` and `traefik/`
- `clusters/my-cluster/config/` — the layer's `kustomization.yaml`, plus `certificates/`
- `apps/wildcard-home-cert.yaml` — the shared wildcard certificate
- `apps/home-assistant/` and `apps/immich/` — two example application deployments
- `apps/authentik/` — the Traefik `Middleware` files for the ForwardAuth chain

Not everything the cluster runs is published, so some references point at files that are not included. For example, the root and layer `kustomization.yaml` files also list unpublished layers and directories such as `rbac/`.

## Reconciliation Layers

Flux reconciles four Kustomizations in dependency order from a single Git source, polling `main` roughly once a minute:

```
infrastructure   → cert-manager, traefik

config           → ClusterIssuers, wildcard certificate, RBAC   (dependsOn: infrastructure)
migrations       → secret-generating Jobs                        (dependsOn: infrastructure)
                   (runs in parallel with config, not sequentially after it)

apps             → all application services                     (dependsOn: config + migrations)
```

The explicit root `clusters/my-cluster/kustomization.yaml` is a safeguard that stops Flux from auto-discovering subdirectories and bypassing the `dependsOn` chain — without it, Flux could try to apply Certificate resources before cert-manager's CRDs exist.

## Conventions

### Shared wildcard certificate

A single `Certificate` resource in `apps/wildcard-home-cert.yaml` covers the home domain, and every Ingress references `secretName: wildcard-home-tls` with `ingressClassName: traefik-traefik`. Per-service certificates are banned: DNS-01 validation creates an `_acme-challenge.<service>` TXT record, which makes that subdomain exist as an empty non-terminal in DNS and causes the wildcard record to be skipped for that specific name.

### ForwardAuth middleware chain

Services with no native authentication support are protected by a Traefik `Middleware` chain under `apps/authentik/`. `middleware-chain.yaml` defines `authentik-auth`, which runs `middleware-strip-headers.yaml` first, clearing any client-supplied `X-authentik-*` and `Authorization` headers so identity cannot be spoofed, and then `middleware-forwardauth.yaml`, which asks the Authentik outpost to authenticate the request and copies back only the `X-authentik-*` response headers.

`middleware-strip-authentik-headers.yaml` and `middleware-strip-authorization.yaml` are the building blocks of a separate HTTP Basic variant of the chain, which keeps `Authorization` so the outpost can see it and strips it after authentication. The chain file for that variant is not included.

## Read more

- [GitOps for Home Labs with Flux CD and k3s](https://www.bstjohn.net/blog/gitops-homelab-flux-k3s/)
- [Automated Wildcard HTTPS Behind NAT with Let's Encrypt](https://www.bstjohn.net/blog/wildcard-https-letsencrypt-nat/)
- [Single Sign-On for the Home Lab with Authentik](https://www.bstjohn.net/blog/homelab-sso-authentik/)
