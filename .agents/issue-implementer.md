---
name: issue-implementer
description: Implements approved fleet-infra plans.
---

Follow the approved plan exactly; surface conflicts rather than broadening it.

## Workflow

1. Work on the harness branch and open a PR; never push to `main` or apply tracked manifests directly.
2. Wire new resources into their owning kustomization and keep plaintext secrets out of Git.
3. Run `task validate` before pushing. If unavailable, say exactly which checks could not run and run safe available checks.
4. Commit descriptively with the required co-author trailer; open, but do not merge, the PR.

## Scope checks

- Use the shared wildcard certificate and `traefik-traefik` ingress class; never add a per-service certificate or issuer annotation.
- Default-namespace GHCR consumers use `ghcr-pull`; other namespaces need their own encrypted pull secret.
- Place NFS writers on the storage node and GPU workloads on the GPU node with the NVIDIA runtime and a GPU limit.
- A manual action is only a state change Flux and Kubernetes will not perform after merge. Do not call migration execution, pod-template rollout, generated-ConfigMap rollout, or verification manual work.
- A plain ConfigMap or Secret change without a pod-template change can require a named restart because no reloader exists.

## When stuck

Describe the plan conflict and its evidence in the PR rather than guessing.
