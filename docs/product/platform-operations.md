# Platform operations

**Reference**

Read this when proposing cluster-wide capacity, delivery, image-distribution, or enforcement changes.
Read [PRODUCT.md](../PRODUCT.md) first; read [OVERVIEW.md](../OVERVIEW.md) for the current implementation.

## Problem

The platform is intentionally small and private, so operational shortcuts can create outages or weaken its supply-chain boundary.

## Users

The household relies on the services; the operator needs predictable, maintainable changes.

## Requirements

### Never use horizontal autoscaling for this cluster

Address overload with resource tuning, priority, or deliberate placement rather than an HPA.

**Why:** The cluster has one node for each role, not a pool of interchangeable capacity; CPU scaling does not describe its real constraints.

### Never make organisation images or packages public to bypass pull authentication

Fix credentials, secret wiring, or publication to the private registry when image pulls fail.

**Why:** The owner treats images as private infrastructure and wants authenticated pulls or self-hosted publication, not a visibility downgrade.

### Make policy-drift detection advisory rather than a blocking PR gate

An automated check for a convention such as image-tag pinning should report drift on the default branch as an issue.

**Why:** The owner explicitly rejected failing unrelated PRs for post-merge policy drift.

### Keep application image builds outside this repository

This repository deploys pinned images but does not build them.

**Why:** Dedicated source repositories own their builds and release handshakes, keeping GitOps deployment configuration focused.

### Never give an automation runner standing egress to the public internet for a dependency download

An infrastructure automation runner (e.g. the tofu/UniFi runner) must resolve its dependencies from a pinned, pre-built offline mirror rather than carrying a NetworkPolicy rule that allows egress to arbitrary public hosts at runtime.

**Why:** The owner's stated intent is that such a runner "cannot phone home at all" — a malicious dependency release that survived the lockfile/soak gate could otherwise still exfiltrate credentials or configuration to any public host; the version lockfile is the primary control but was never meant to be the only one.

### Never run more than one Claws replica, or surge during its rollout

Claws deploys as a single-replica workload with no surge during image updates, even at the cost of rollout downtime.

**Why:** Claws is not safe to run twice — its dispatchers, work queue, scheduled jobs and session reconciliation all assume a single instance; true zero-downtime rollouts would need leader election or blue/green support inside Claws itself, which does not exist yet.

### Automerge low-risk dependency bumps once CI and review are clean

Renovate minor/patch/pin/digest updates and image-bump receiver PRs (e.g. Forgejo, claws) merge unattended once CI is green and the automated review is clean, rather than stalling for a human LGTM. Major upstream-version updates and OpenTofu changes always keep a human merge gate. An unattended bump receiver must itself refuse any tag that is not a strict upgrade over what is deployed — including an older build sharing the same upstream version — never just a lower upstream version.

**Why:** The owner wants routine, low-risk dependency PRs to stop stalling for a manual LGTM when automated checks already cover them, but only so long as the receiver's own ordering check can't be fooled into rolling a live service backward (an unattended merge of a same-version older build once did exactly that, rolling Forgejo and its backup CronJob back to a stale build).

### Require measured historical usage before raising a workload's resource limit

A memory or CPU limit is not raised on assumption; the change is backed by measured capacity data (e.g. cgroup peaks, node headroom) showing the new ceiling is actually safe.

**Why:** The owner explicitly required a historical capacity review before an existing serialization/limit imposed for real capacity reasons could be relaxed, rather than treating the original limit as merely cautious.

### Publish CI previews and rendered docs to a private in-cluster pages host

Generated HTML, SVG and PNG from CI or Claws is published to `pages.home.bstjohn.net` — LAN/tailnet only, behind Authentik — under a predictable `/<repo>/<kind>/<ref>/<sha8>/` path, with a centrally rotatable write credential, automatic cleanup, an enforced size cap, and a documented disposability classification.

**Why:** GitHub and Forgejo render HTML poorly and hand reviewers zipped artifacts, and the only existing publish target (3d-models' public `www.bstjohn.net` bucket) makes content public and costs a new AWS OIDC role and CloudFront exposure per repo — wrong for private repos.

## Non-goals & rejected ideas

- A permanent migration script for deleting a known, unmounted, untracked rollback object. Verify and remove such garbage interactively; migrations are for repeatable desired state.
- Serving CI previews from Claws. Claws is the automation service, not a file server, and Forgejo CI must not depend on it being up.

## Open questions

- Which advisory policy checks, beyond tag pinning, should be introduced first?
