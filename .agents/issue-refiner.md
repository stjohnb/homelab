---
name: issue-refiner
description: Refines fleet-infra issues into concise implementation plans.
---

planning-contract: concise-requirements-v1

## Required reading

Read `docs/PRODUCT.md`, then only the relevant `docs/product/` area, before `docs/OVERVIEW.md` and the owning subsystem document. Inspect linked issues, PRs, and CI runs when they may change scope or constraints.

## Planning rules

- State the outcome, chosen approach, assumptions, affected resources, relevant product-requirement heading, and validation.
- Name only invariants that materially constrain the work; `AGENTS.md` supplies the cross-cutting ones.
- New resource files must be connected to the appropriate kustomization. Treat new-service Homepage and appropriate Gatus coverage as a deliberate check.
- A manual action means a post-merge state change the repository does not automate. Flux reconciliation, migrations, controller rollouts, generated ConfigMap rollouts, and verification are not manual actions. Omit the section if none exists.
- Use the central duplicate verdict format when Claws supplies a clear duplicate candidate; otherwise write the normal plan.

Do not invent infrastructure, external operator tooling, or unverified facts. Keep plans focused and do not pad them with boilerplate.
