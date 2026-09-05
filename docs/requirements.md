# Standing Requirements

**Reference.** Read this when proposing something cross-cutting — autoscaling, a new auth/CI pattern, a policy-enforcement gate — to check whether the owner already rejected it. Subsystem-specific constraints live in that subsystem's doc instead; see [OVERVIEW.md](OVERVIEW.md) for the doc map.

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

## Do not make org images or packages public to paper over auth problems

When pull auth breaks, the owner does **not** want the fallback to be "just make the
package public". That position is tied to the broader GitHub-exit direction for the org:
images are private infrastructure, and the durable direction is either authenticated pulls
or moving publication to the self-hosted registry (`registry.home.bstjohn.net`), not a
visibility flip.

**How to apply**: For GHCR or registry auth failures, fix credentials, Secret wiring, or
image publication/hosting. Do not propose making packages public unless the owner
explicitly changes that policy.

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

## Don't invent operator tooling/product names in docs

PR #937 reworded `docs/forgejo-mirroring.md` after an implementer wrote that the push-mirror
PAT lives in "1Password" — a product the operator does not actually use. The name was invented
to fill in a plausible-sounding detail rather than left generic or asked about.

**How to apply**: When documenting where the operator keeps a credential, runs a tool, or
manages some out-of-repo process, and the actual product/service isn't stated anywhere in the
repo or conversation, use a generic description ("the operator's password manager", "an
external monitor") instead of naming a specific product. Don't backfill specifics that were
never confirmed.

## Explicitly rejected feature ideas

### A permanent migration script for one-off cluster object cleanup (#1007, PR #1058 closed without merging)

When #996's Postgres consolidation left two unmounted, prune-disabled rollback PVCs
(`authentik-postgresql-data`, `immich-postgres-pvc`) with nothing in Git referencing them, the
planned fix was a new numbered migration script (`migrations/0030-...`) to delete them once a
trust window had elapsed. @stjohnb closed the PR unmerged and did the deletion by hand in an
interactive session instead (`kubectl delete pvc ... --wait=false`, after checking
`mounted-by` and the backup CronJobs' last-success timestamps).

Reasoning: neither PVC was referenced by anything in Git, so this was garbage collection of
untracked objects, not a Git-to-cluster change — the kind of thing a migration script exists
to do. A migration would have needed a permanent RBAC carve-out for a one-time deletion, left
dead code behind after it ran once, and gained nothing in safety that manual verification
didn't already provide.

**How to apply**: For deleting a specific, already-identified, unmounted, prune-disabled
object that nothing in Git references — a rollback PVC, a leftover Secret from a completed
cutover, etc. — do it by hand in an interactive session with real verification (confirm
nothing mounts it, confirm a recent successful backup exists if relevant), not via a new
permanent `migrations/` script. Reserve `migrations/` scripts for changes that must reproduce
automatically on a fresh cluster or on every reconcile — see [apps-overview.md](apps-overview.md#secret-migration-jobs).
