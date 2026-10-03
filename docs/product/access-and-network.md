# Access and network

**Reference**

Read this when changing authentication boundaries, remote routes, UniFi, or access to administrative services.
Read [PRODUCT.md](../PRODUCT.md) first; read [authentik.md](../authentik.md) or [unifi.md](../unifi.md) for implementation details.

## Problem

Household services need convenient access without exposing administrative systems or relying on unmanaged console configuration.

## Users

Household members use services through the home and tailnet domains; the operator administers protected systems.

## Requirements

### Protect the UniFi console through the household SSO boundary

Both home and tailnet console hosts require an Authentik session for authorised infrastructure users, while direct LAN access remains a break-glass route.

**Why:** The operator wants central access control without risking loss of local console recovery or API clients that use the gateway directly.

### Keep remote browser debugging home-only and separately token-protected

The shared browser debugger is available only through the home host, Authentik, and its service token.

**Why:** A remotely controlled browser can reach private resources and persistent logins, so SSO supplements rather than replaces the service credential.

### Manage the UniFi network declaratively only after a recoverable backup exists

Network configuration is planned and reviewed in Git; applying changes remains a deliberate later decision.

**Why:** The isolated IoT network must be recoverable before automation can write to the gateway.

### Own only what this repo creates in UniFi, never bulk-import existing console state

Pre-existing console objects (the default LAN, built-in firewall zones) are referenced with Terraform data sources, not imported and managed; only selective, deliberate `import` of one resource at a time is allowed later, and a bulk import never is.

**Why:** So nothing already in the console is put at risk by, or dependent on, the first and subsequent plans — only resources this repo actually creates are on the hook for drift correction.

### Fail closed when UniFi apply credentials are missing

The UniFi Terraform runner's console-credentials Secret reference must not be made optional; a missing Secret leaves the runner `NotReady` rather than proceeding without credentials.

**Why:** The owner explicitly rejected making the credential reference optional — failing closed is the intended behaviour, especially once the CR moves off plan-only to auto-apply, where silently skipping credentials could apply an incomplete plan.

### Never let the in-cluster tailnet DNS resolver become an open resolver

Forwarding rules the tailnet resolver adds must stay scoped to the household's own domain; anything outside it is refused rather than forwarded.

**Why:** Stated directly by the owner — the resolver is never to become an open resolver, even as its forwarding scope has grown to cover the whole domain instead of one subdomain.

### Derive Grafana's authorisation level from Authentik group membership

Grafana's org role is assigned from Authentik group membership on every proxy login — `infra` (or `authentik Admins`) members and the `claws-admin` service account administer Grafana as Admin; everyone else, including the `claws-reader` service account, reads as Viewer.

**Why:** A role set by hand in Grafana's database is console drift, invisible to Git, and lost outright on a Grafana PVC rebuild.

## Non-goals & rejected ideas

- Native single sign-on inside the UniFi UI; the supported design gates the existing local login with ForwardAuth.
- Making the UniFi Terraform runner's credentials Secret reference optional to avoid a `NotReady` state — failing closed is intended, not a bug.

## Open questions

- When should the current plan-only UniFi configuration be promoted to apply?
