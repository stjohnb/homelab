# Standing Requirements

Cross-cutting constraints from the repo owner (@stjohnb) that don't belong to any single
subsystem doc. Requirements that *do* belong to a subsystem (auth, monitoring, storage, CI,
etc.) are recorded as constraints-with-rationale in that subsystem's doc instead — see
[OVERVIEW.md](OVERVIEW.md) for the full list. This file is a coverage backstop, not a catch-all.

## Do not add autoscaling (HPA)

This is a single-node-per-role home cluster (one control-plane/main node, one NAS
storage node, one GPU node) — there is no fleet of interchangeable nodes for a
HorizontalPodAutoscaler to scale a service across, and CPU-based scaling doesn't reflect a
real capacity constraint here (#193). A `HorizontalPodAutoscaler` was explicitly removed
for this reason and none has been re-added since.

**How to apply**: When a service seems slow or overloaded, address it with resource
`limits`/`requests` tuning, `priorityClassName`, or a node move — not an HPA. Do not propose
adding an HPA to any service in this repo.

## Prefer mirroring `production-infra` over inventing new designs

`production-infra` is a sibling GitOps repo (see [[reference_production_infra]] in memory)
that hit and solved several of the same problems earlier — most notably the GHCR
static-PAT-over-SOPS pattern (see [ghcr-auth.md](ghcr-auth.md)) and the
`workflow_dispatch` + PAT release-bump pipeline with Claws-driven auto-merge (see
[infrastructure-overview.md](infrastructure-overview.md)). Both were adopted here *because*
they were already proven there, not designed from scratch (#504, #533, PR #655, PR #663).

**How to apply**: Before designing a new auth flow, CI automation, or secret-provisioning
mechanism for this repo, check whether `production-infra` already has a working pattern for
it and copy that instead of proposing something new. This applies most often to
GitHub-token-based automation and cross-repo dispatch, where the two repos' constraints
are nearly identical.

## Policy-drift checks should file an issue, not fail CI

Image tag pinning (see [apps-overview.md](apps-overview.md#image-pinning)) is currently
enforced only by human review — nothing in CI stops a PR from introducing a floating tag
like `:latest`, `redis:7`, or `postgres:16-alpine` (#95), and Renovate can't help retroactively
since it only tracks tags that already exist in the repo. A future automated check for this
(or similar post-merge policy-drift detectors) should **open a GitHub issue when drift is
found on `main`, not fail the build** — @stjohnb explicitly rejected the blocking-CI-job
version of this idea ("Maybe just create an issue when this is detected on main, don't fail
the build").

**How to apply**: When proposing automated enforcement for a policy that's currently only
kept by convention/review (image pinning or similar), default to an advisory issue-filer
that runs against `main` post-merge, not a blocking PR check — unless the owner asks
specifically for a hard gate.
