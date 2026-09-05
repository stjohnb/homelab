# fleet-infra Agent Guide

`fleet-infra` is the GitOps source of truth for a homelab k3s cluster. It holds both cluster-layer infrastructure under `clusters/` and application manifests under `apps/`, with Flux CD reconciling merged changes into the live cluster.

## Where To Read First

Read [`docs/OVERVIEW.md`](docs/OVERVIEW.md) before planning or implementing changes. It is the main index for architecture, subsystem docs, constraints, and operational gotchas.

## Key Conventions

- All cluster changes land via pull request; nothing is pushed directly to the default branch. See [`docs/claws-automation.md`](docs/claws-automation.md) for the full workflow and automation conventions.
- This repo is Flux-managed GitOps. Do not use `kubectl apply` as the delivery path for tracked manifests; debug-only exceptions still need the Git change afterward.
- Use the shared wildcard certificate in [`apps/wildcard-home-cert.yaml`](apps/wildcard-home-cert.yaml). Do not add per-service `Certificate` resources or `cert-manager.io/cluster-issuer` ingress annotations.
- Treat [`migrations/`](migrations/) as automatic. Merged migration changes are picked up by Flux; do not describe "run the migration" as a manual step.
- Keep public-snapshot constraints in mind when touching top-level docs: [`README.public.md`](README.public.md) is hand-maintained, scrubbed for public publication, and must never gain secrets or links to scrubbed private docs/idea files.

## Automation Host Policy

Claws agents work on a shared, resource-constrained automation host that also runs the Claws service itself. When working on this repo as an agent:

- Do not start dev servers or other long-running processes (`npm run dev`, `npm start`, `docker compose up`, watchers, tunnels). Verify with fast one-shot checks and leave live-app or end-to-end coverage to CI.
- Do not install system packages or browser binaries on the host: no `sudo`, no `apt-get install`, no `npx playwright install`, no `brew install`. If CI needs a tool, add it to the repo-owned toolchain instead.
- Never kill a process or free a port you do not own. Commands such as `lsof -ti:PORT | xargs kill` and `pkill -f node` can take down the Claws service, whose dashboard listens on port 3000.
