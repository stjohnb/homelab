# fleet-infra product requirements

**Entry point**

Read this before planning a change: it states what this homelab platform must do and why.
Choose the relevant area below, then read the implementation overview for how the repository fulfils it.

fleet-infra is the GitOps source of truth for a small, single-household k3s homelab. It gives its operator dependable, private services and infrastructure that can be changed through reviewed Git rather than console drift. It is for the household and the operator maintaining its network, storage, identity, and self-hosted applications.

## Goals

- Keep services and infrastructure reproducible through GitOps.
- Prefer private, operator-controlled services and image distribution.
- Preserve safe recovery paths for data and network changes.
- Keep the platform understandable and operable on its deliberately small hardware footprint.

## Non-goals

- High availability or elastic horizontal scale.
- Making private images public to avoid credential work.
- Replacing every application’s native authentication with SSO.
- Treating temporary migration or cleanup work as permanent platform machinery.

## Areas

| Area | Read this when | Doc |
| --- | --- | --- |
| Platform operations | Changing cluster-wide delivery, capacity, image, or policy choices | [Platform operations](product/platform-operations.md) |
| Access and network | Changing SSO, remote access, UniFi, or protected administrative services | [Access and network](product/access-and-network.md) |
| Data protection | Changing backups, migration, storage, or recovery behaviour | [Data protection](product/data-protection.md) |

## Cross-cutting constraints

- Changes must be reviewable and delivered through pull requests; Flux reconciles tracked state after merge.
- Document only confirmed operator tooling and external systems; leave an unknown product generic rather than inventing one.
- When a proven pattern already exists in the sibling `production-infra` repository, prefer it over a new design unless its constraints differ.
