# Postmortem: Authentik outage from an auto-merged two-train version jump

- **Date:** 2026-09-24
- **Author:** Claws interactive session (Claude Fable 5.1), reviewed by the operator
- **Status:** final
- **Severity:** Full SSO outage. Every ForwardAuth-protected `.home.` and `.ext.` host and every OIDC login (Grafana, Forgejo, Jellyfin, Seerr, Proxmox, Headlamp, …) failed for about 96 minutes. No data loss.
- **Incident issue:** [#1596](https://github.com/St-John-Software/fleet-infra/issues/1596)

## Summary

Renovate PR [#1593](https://github.com/St-John-Software/fleet-infra/pull/1593) bumped `ghcr.io/goauthentik/server` and `ghcr.io/goauthentik/proxy` from `2026.2.1` straight to `2026.8.3`, was classed as a minor update, carried `Automerge`, and merged unattended; Authentik refuses to migrate across a skipped `YYYY.M` release train, so `authentik-server` and `authentik-worker` crash-looped before serving and `authentik-proxy-ext` never became Ready. Every SSO login on the cluster failed from 12:09Z until 13:45Z. Fix PR [#1598](https://github.com/St-John-Software/fleet-infra/pull/1598) stepped the three images forward to `2026.5.7` (the database had not been touched, and the 2026.5 train has no skip check) and removed `Automerge` from Authentik minor bumps in `renovate.json`.

## Impact

- All Authentik-backed logins failed for 1 h 35 min (12:09:24Z to 13:44:58Z): the embedded outpost (12 `.home.` proxy providers), the standalone `.ext.` outpost (12 providers) and every OIDC client. Sessions already established kept working until they expired or the app re-validated.
- Blueprint changes could not apply while the worker was down; the in-flight Mealie SSO issue was blocked on it.
- Five Grafana alerts fired and were consolidated into #1596; three Gatus Slack alerts fired.
- No data loss: the Authentik database was never migrated by 2026.8.3, because the version check runs before any migration.

## Timeline

| Time (UTC) | Event | Source |
| --- | --- | --- |
| 2026-09-14 20:00:20 | #1357 merged: Renovate minor/patch/pin/digest PRs get the `Automerge` label (resolves #1353) | `git log -- renovate.json` (`015fd3b`); `gh pr view 1357` |
| 2026-09-23 16:42:12 | #1568 merged: Renovate moves to a daily schedule and `minimumReleaseAgeBehaviour: timestamp-optional`, which lets ghcr.io images that had been "pending" indefinitely proceed (resolves #1565) | `git log -- renovate.json` (`8bcf3e9`) |
| 2026-09-24 11:25:02 | First daily Renovate run after #1568 starts (run `35992886806`) | `gh run list --workflow renovate.yml` |
| 11:29:09 | PR #1593 opened: `authentik` group, update type **minor**, `2026.2.1 → 2026.8.3`; `Automerge` label applied at 11:29:11 | `gh pr view 1593`; issue events |
| 11:40:41 | Claws review iteration 1: **Approve** with two advisory notes (2026.8 trusted-proxy CIDR change, stale version in `docs/authentik.md`); auto-merger blocks at 11:40:49 because the review status is `issues` | PR #1593 comments |
| 11:55:04 | Claws review addresser: both notes non-blocking, no change made | PR #1593 comments |
| 12:00:41 | CI run `35993289734` on the PR completes green | `gh run list --workflow ci.yml --branch renovate/authentik` |
| 12:08:03 | Review comment updated to iteration 2, `review-result: clean`; `Ready` label at 12:08:06 | PR #1593 comment `updated_at`; issue events |
| 12:08:12 | **Change landed**: #1593 merged by the Claws auto-merger (`6ba3ccf`) | `gh pr view 1593 --json mergedAt,mergedBy` |
| 12:09:24 | **Defect became live**: Flux applies; new ReplicaSets `authentik-server-6c8ccbfdf9` and `authentik-proxy-ext-5fd7c58b86` created (worker at 12:09:29). `Recreate` strategy terminates the healthy 2026.2.1 server pod | `kubectl get rs -n default` creation timestamps |
| 12:10:17 | **First symptom**: first `BackOff` event on the `authentik` container of the new server pod; log ends `RuntimeError: Major version skips are not allowed … from=2026.2.1&to=2026.8.3` | `kubectl get events`; `kubectl logs --previous` |
| 12:12:23 | **Detected**: Gatus sends Slack alerts for `Authentik`, `Authentik Worker` and `Authentik Ext Outpost` down | `kubectl logs deploy/gatus` |
| 12:21:00 | Grafana `Workload Crash Looping` (`for: 10m`) starts firing | #1596 body |
| 12:22:08 | Issue #1596 opened by grafana-github-alerts | `gh issue view 1596 --json createdAt` |
| 12:25–12:36 | `Authentik Worker Metrics Target Down`, `Workload Deployment Replicas Mismatch`, `Workload Pod Not Ready`, `Workload Rollout Stalled` join the issue | #1596 body |
| 13:02:49 | Correct diagnosis (skipped train) posted on #1596 by the Planner of an unrelated issue (Mealie SSO, `clw_01M39KBYFPHHRQ7G0KY352GPQ4`) that hit the outage while investigating | #1596 comments |
| 13:16:59 | Claws `issue-refiner` starts on #1596 (55 min after the issue opened; cause `unknown`, see action item 3) | `claws_task_history` for item 1596 |
| 13:23:41 | Implementation plan posted, #1596 labelled `Ready` | #1596 comments; issue events |
| ~13:26 | Operator opens an interactive Claws session and asks for direct action rather than the `Refined` flow | this session |
| 13:28:29 | PR #1598 opened: step to `2026.5.7`, Renovate rule change, docs | `gh pr view 1598` |
| 13:42:24 | **Mitigated**: #1598 merged (`2cf7a01`), all 22 CI checks green; #1596 closed by the merge at 13:42:26 | `gh pr view 1598`; issue events |
| 13:43:28 | Flux fetches `main`, new ReplicaSets for all three Deployments created | `kubectl get gitrepository`; `kubectl get rs` |
| 13:44:09 | `authentik-worker` Ready | pod `Ready` condition |
| 13:44:14 | Server migrations from 2026.2.1 to 2026.5.7 complete, `releasing database lock` | `kubectl logs deploy/authentik-server` |
| 13:44:26 | `authentik-server` Ready | pod `Ready` condition |
| 13:44:58 | **Resolved**: `authentik-proxy-ext` Ready; `/-/health/ready/` returns 200 on both `auth.home.` and `auth.ext.` | pod `Ready` condition; `curl` |
| 13:45:23 / 13:46:23 | Gatus resolves the worker and server alerts | `kubectl logs deploy/gatus` |

## Metrics

- **Time to detect:** 3 min (12:09:24 → 12:12:23, Gatus Slack). 12 min 44 s to the tracked issue (→ 12:22:08, Grafana → #1596).
- **Time to mitigate:** 1 h 33 min (12:09:24 → 13:42:24, fix merged). Of that, 53 min passed before any correct diagnosis existed and 66 min before a fix PR was opened.
- **Time to resolve:** 1 h 35 min 34 s (12:09:24 → 13:44:58, all three Deployments Ready on 2026.5.7).

## Contributing factors

1. **Calendar versioning was classed as semver-minor.** Authentik's releases are `YYYY.M` trains (2026.2, 2026.5, 2026.8) and each train is a major upgrade in everything but its version string; from 2026.8, `lifecycle/migrate.py` `ensure_allowed_version` refuses to start unless the database is on the current or immediately previous train. Renovate's Docker datasource sees `2026.2.1 → 2026.8.3` as a minor bump. The blanket rule from #1357 gives every minor bump `Automerge`, which is correct for semver upstreams and wrong for this one. Nothing in the repo recorded that Authentik was different; `docs/authentik.md` had no upgrade section.

2. **A policy change the day before released a months-old backlog in one step.** Until #1568 (2026-09-23), every ghcr.io image sat under Renovate's release-age gate indefinitely because ghcr supplies no release timestamp, so Authentik had been frozen at 2026.2.1 while two further trains shipped. #1568 switched to `timestamp-optional` and a daily schedule; the very next run proposed the newest tag. Renovate proposes the highest satisfying version, not the next one, so a long freeze followed by an unblock produces exactly the multi-train jump the upstream forbids. The #1565 plan discussed rate limits, release age and major routing but did not enumerate which dependencies would become auto-mergeable, or check their versioning scheme.

3. **The automated review looked at release notes, not the upgrade path.** The Claws reviewer read the 2026.8 release notes and raised the trusted-proxy change as an advisory note, which shows the right instinct, but the skip restriction lives in upstream's upgrade documentation and in code, not in release notes or the diff. `.agents/pr-reviewer.md` has no rule for dependency bumps, so there was no prompt to ask "does the upstream allow going from the old version to the new one directly?" With `Automerge` set, no human read the PR at all.

4. **No gate between merge and outage.** CI validates manifest shape and that the image tag exists; it cannot know database-version compatibility. Flux applies whatever merges. The server Deployment uses `Recreate` (required: two servers must not migrate concurrently), so the healthy old pod was terminated before the new one first crashed. A failed rollout of this Deployment is therefore a full outage rather than a degraded one, and no automation can roll it back.

5. **Diagnosis and mitigation ran through the slow path.** The alert reached Slack in 3 minutes and GitHub in 13, but the tracked issue then waited 55 minutes for its first Planner run (cause not established from this repo). The correct diagnosis arrived 40 minutes earlier than that, from the Planner of an unrelated issue that happened to hit the outage. The fix itself, once someone acted on it, took 17 minutes end to end.

6. **No prior incident of this class.** `docs/postmortems/` was empty and a closed-issue search for Authentik upgrade, migration, crash-loop and version-skip terms found no earlier occurrence in this repo. #1353 and #1565 are the policy lineage that made this possible, not recurrences.

## Detection ladder

| Rung | Would it have caught this? | Why / why not | Change that would make it catch this |
| --- | --- | --- | --- |
| 1. Design / issue refinement | Yes | The failure mode was foreseeable when the Renovate policy was designed: #1353 made every "minor" auto-mergeable and #1565 unblocked a months-old ghcr backlog. Either plan could have listed the dependencies that would become auto-mergeable and noticed that Authentik, already pinned at `2026.2.1`, uses calendar trains. Neither did. | When a change widens what Renovate may merge unattended (update types, release-age gate, schedule), the plan lists the affected dependencies and checks their upstream versioning scheme. Done for Authentik in #1598 (`renovate.json`: Authentik minors get `major-update`, never `Automerge`). |
| 2. Human PR review | Yes, had a human looked | The diff plainly shows `2026.2.1 → 2026.8.3`, skipping the 2026.5 train, and upstream's upgrade docs say skips are refused. `Automerge` removed the human, and the automated reviewer had no rule telling it to check the upgrade path for a multi-step jump. | Add a dependency-bump rule to `.agents/pr-reviewer.md`: a multi-minor or calendar-versioned jump requires reading the upstream upgrade docs, and a version-skip restriction is blocking (action item 2). |
| 3. Automated pre-merge checks | No | CI run `35993289734` ran every job for this change (`ci.yml` triggers on all PRs, no path filter excluded it) and passed. The checks validate manifests, schemas, image existence and secrets; none can observe database-version compatibility, and no generic check can know an upstream's train semantics. | n/a as a CI check. The pre-merge control that fits is Renovate policy (rung 1), now in place. |
| 4. Merge gate | No | The gate is `Automerge` label + green CI + clean Claws review of the current commit, and all three were satisfied by design. | #1598 excludes `ghcr.io/goauthentik/**` from the blanket `Automerge` rule; Authentik minors now wait for a human `LGTM` with a PR-body note about trains. Done. |
| 5. Deploy-time verification | No | Flux applies on merge with no health gate and no rollback; `Recreate` had already removed the healthy pod. A Flux health check on the `apps` Kustomization would surface `Ready=False` after the progress deadline but could not prevent or undo the outage. | n/a. Gatus already detects in 3 minutes (rung 6). |
| 6. Runtime monitoring / alerting | Yes, and it did | Gatus Slack alerts at +3 min; Grafana `Workload Crash Looping` at +12 min opened #1596 with the exact `kubectl logs --previous` command to run. | n/a. The gap after detection was pipeline latency, not alerting (action item 3). |
| 7. User report | Yes | Any SSO login attempt failed immediately and visibly. Not needed here because rung 6 fired first. | n/a. |

**Shift-left target:** Rung 1 (design / issue refinement of Renovate merge policy)

## What went well

- Detection was fast and specific: Gatus in 3 minutes, and the Grafana issue quoted the crash-looping pod and the exact `--previous` log command.
- Authentik's version check runs before any migration, so the database was untouched and a forward step to 2026.5.7 was safe. No restore was needed.
- The Planner for an unrelated issue produced a correct root cause with the log line and a fix path within an hour, and the #1596 plan verified the upstream `VERSION_FAMILY_PREVIOUS` and the ghcr tags before proposing them.
- Once acted on, the fix took 17 minutes from PR open to all pods Ready, including a full 22-check CI run. Flux picked up the merge within a minute of a reconcile nudge.
- The fix PR bundled the policy change and documentation with the image step, so the repo now records why Authentik is special.

## Action items

| # | Action | Class (prevent/detect/mitigate) | Issue | Status |
| --- | --- | --- | --- | --- |
| 1 | `renovate.json`: exclude `ghcr.io/goauthentik/**` from the blanket `Automerge` rule; Authentik patch bumps keep `Automerge`, Authentik minors get `major-update` plus a `prBodyNotes` train warning. Document the train rule in `docs/authentik.md` "Upgrades". | prevent | [#1598](https://github.com/St-John-Software/fleet-infra/pull/1598) | done (merged 2026-09-24 13:42Z) |
| 2 | `.agents/pr-reviewer.md`: add a dependency-bump rule that a multi-minor or calendar-versioned jump requires checking the upstream upgrade path, with a version-skip restriction treated as blocking. | prevent | [#clw_01M39TVF7VWZ3W5GHC14EQE2Z1](https://claws.home.bstjohn.net/issues/clw_01M39TVF7VWZ3W5GHC14EQE2Z1) | open |
| 3 | Claws: establish why #1596 waited 55 minutes for its first `issue-refiner` run and make `grafana-alert` issues start planning within one dispatcher cycle. | mitigate (faster) | [#clw_01M39TVVMJBC3MNXW610HA6K8X](https://claws.home.bstjohn.net/issues/clw_01M39TVVMJBC3MNXW610HA6K8X) (claws repo) | open |
| 4 | Complete the upgrade to 2026.8.3 through the human-gated Renovate PR that the next daily run opens, only after confirming `authentik-server` is Ready on 2026.5.7. | mitigate | Renovate PR (pending, no separate issue) | pending |

## Considered and rejected

| Action | Why not |
| --- | --- |
| Revert to `2026.2.1` and step forward later | The database had not been migrated by 2026.8.3 and the 2026.5 train has no skip check, so a forward step was equally safe, one rollout shorter, and left the fleet less stale. |
| Set `AUTHENTIK_MIGRATIONS__DANGEROUSLY_ALLOW_MULTIPLE_MAJOR_VERSION_UPGRADES` to bypass the check | Upstream names it dangerous for a reason: the intermediate train's migrations are skipped. Not acceptable for the SSO database. |
| Renovate `separateMultipleMinor` so Renovate proposes one train at a time | Marked experimental in Renovate's option definitions and its interaction with the existing `groupName: authentik` branch naming is unverified. The human gate plus PR-body note is sufficient. |
| Audit other calendar-versioned images and add matching rules | `grep` over `apps/` and `clusters/` shows Authentik is the only image with a `YYYY.M` tag today. The reviewer rule (action item 2) covers any future addition. |
| A CI job that fails when an image bump crosses more than one upstream minor | CI cannot know an upstream's train semantics; a generic threshold would block legitimate semver minor jumps. Renovate policy is the right layer, and it is in place. |
| Flux `healthChecks` and `wait` on the `apps` Kustomization | Flux does not roll back a Kustomization, and `Recreate` had already removed the healthy pod. It would add a second alert several minutes after Gatus, not prevention. |
| Switch `authentik-server` to `RollingUpdate` so the old pod survives a failed rollout | Two servers running migrations concurrently is exactly what `Recreate` prevents; upstream requires a single migrator. Not safe. |
