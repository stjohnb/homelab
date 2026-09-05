# Forgejo Repository Mirroring

**Reference.** Read this when working on push mirrors from in-cluster Forgejo to GitHub. For Forgejo itself, see [forgejo.md](forgejo.md).

## Purpose

Forgejo (`git.home.bstjohn.net`) runs *inside* the cluster that `fleet-infra` manages. If the cluster is down, the repo needed to rebuild it is unreachable. A live GitHub push mirror is the "cluster is down and I need the code now" path. It is not a substitute for backups (`forgejo dump`) — a mirror carries git refs only, not issues, PRs, users, or Actions history.

## Direction rules

**Exactly one side is canonical for a repo at any moment. Never both.**

- Migrated repos: **Forgejo is canonical, GitHub is a read-only push mirror.**
- Not-yet-migrated repos: **GitHub is canonical, Forgejo holds nothing** (or a throwaway import).
- Pull mirrors (GitHub → Forgejo) are disabled server-side via `FORGEJO__mirror__DISABLE_NEW_PULL=true` in `apps/forgejo/deployment.yaml`. To do a one-off pull-mirror import you must flip that to `"false"` via PR, do the import, and flip it back in the same day.
- A one-shot **migration** (Forgejo's "Migrate Repository" without the mirror checkbox) is *not* a pull mirror and is unaffected by that setting.

## Current mirror inventory

| Repo | Canonical side | GitHub mirror | Notes |
| --- | --- | --- | --- |
| perudo | Forgejo | `github.com/St-John-Software/perudo` | pilot, live since 2026-08-27 (#211) — verified end-to-end via a no-op commit flowing Forgejo → GitHub → GitHub's deploy-to-S3 Action |

Add a row here for every future migration.

## GitHub-side preparation (do this BEFORE creating the mirror)

1. Forgejo push mirrors **force-push** and overwrite the remote. Remove all branch protection rules and rulesets on the GitHub repo's default branch — a protected branch rejects the force push and the mirror silently fails every cycle.
2. Disable GitHub Actions on the mirror (Settings → Actions → General → "Disable actions"). Otherwise every mirror push re-runs CI on GitHub, duplicating builds and Slack failure notifications.
3. Leave Issues enabled but pin/announce that they are read-only; do **not** archive the repo — an archived GitHub repo rejects pushes, which kills the mirror.
4. Update the GitHub repo description/README to point at `https://git.home.bstjohn.net/<owner>/<repo>`.

## Mirror credential

**Current: SSH deploy key, not a PAT.** The perudo pilot originally planned a GitHub fine-grained PAT (see "Superseded PAT design" below), but what actually shipped for perudo (2026-08-27) is a Forgejo-generated SSH keypair (ed25519) registered as a **write-enabled deploy key** on the GitHub mirror repo. The owner prefers SSH deploy keys over PATs for mirrors: a deploy key is scoped to exactly one repo (a fine-grained PAT is scoped per-owner across whichever repos you pick, which is looser than it sounds once more repos are added), and it carries no forced annual expiry, so there's no PAT-rotation chore at all.

- Generate the keypair from Forgejo's own "Add Push Mirror" UI (see below) rather than `ssh-keygen`, so the private half never leaves Forgejo's DB.
- Register the resulting public key on the GitHub repo under Settings → Deploy keys, with **Allow write access** checked. Nothing else needs granting — a deploy key is inherently scoped to that one repository.
- The private key is **not** a Kubernetes Secret and must not be added to `.sops.yaml`-encrypted files — Forgejo stores it in its own DB, encrypted with the instance `SECRET_KEY`.
- If a mirrored repo has `.github/workflows/` files that change, GitHub still requires the `workflows` scope for pushes that touch them — a write-enabled deploy key covers this the same as a PAT with **Workflows: Read and write** would; perudo does have workflows, so this was exercised and verified during the pilot.

## Creating the push mirror (UI)

Forgejo repo → Settings → Repository → Mirror Settings → "Add Push Mirror":

- Remote Repository URL: `git@github.com:St-John-Software/<repo>.git` (SSH, not HTTPS)
- Tick **"Generate new SSH key"** (or paste an existing one) — Forgejo shows the generated public key to copy into GitHub's Deploy keys page
- Mirror interval: `1h`
- Tick **"Sync when new commits are pushed"**

Register the displayed public key as a GitHub deploy key (Settings → Deploy keys → Add deploy key) with **Allow write access** before the first sync attempt.

## Creating the push mirror (API alternative)

The API also accepts an SSH `remote_address` with a `private_key`; consult the Forgejo API docs for the current field name (it has changed across Forgejo versions). The pilot was set up via the UI's key-generation flow rather than the API, so treat this path as unverified for SSH mirrors.

List existing mirrors with `GET .../push_mirrors`; delete with `DELETE .../push_mirrors/{name}`.

### Superseded PAT design (do not use)

The original plan (2026-07-29, before the pilot ran) called for a GitHub fine-grained PAT scoped to **Contents: Read and write**, stored in the operator's password manager, rotated annually. This is no longer the design — it's kept here only so a reader who finds old references to a `forgejo-push-mirror-github-pat` credential understands why it doesn't exist. Do not create a new PAT-based mirror; use the SSH deploy key flow above.

## Verification

Push a trivial commit to Forgejo, confirm it lands on GitHub within a minute, then check Forgejo → Settings → Mirror Settings shows a recent "Last update" with no error. Also click "Synchronize Now" once and confirm it succeeds.

## Limitations

- LFS objects are not mirrored over SSH push mirrors.
- The wiki is a separate git repo and is not covered by the code push mirror.
- Issues, PRs, releases metadata, and Actions runs are not mirrored at all — those depend on `forgejo dump` backups.

## Credential rotation

SSH deploy keys have no forced expiry, so there is no routine annual rotation like a PAT would need. Rotate only if the key is suspected compromised: generate a new key from Forgejo's Mirror Settings (or `DELETE` + re-`POST` the mirror via the API), register the new public key as the GitHub deploy key, verify with "Synchronize Now", then remove the old deploy key from GitHub.

## Disaster recovery / rebuild

Push-mirror config lives in the Forgejo DB, not in Git. After restoring from a `forgejo dump` backup, verify each mirror still syncs (the `SECRET_KEY` must match or the stored private key will not decrypt). After a *fresh* Forgejo install, re-run the per-repo checklist below — the SSH keypair does not survive a fresh install and must be regenerated.

## Per-repo migration checklist

- [ ] Migrate repo into Forgejo
- [ ] Prep GitHub side (unprotect branch, disable Actions, do not archive)
- [ ] Generate the mirror's SSH keypair from Forgejo's Mirror Settings and register the public half as a write-enabled GitHub deploy key
- [ ] Add the push mirror with `sync_on_commit`
- [ ] Push a test commit and verify on GitHub
- [ ] Add a row to the inventory table in this doc
- [ ] Mark GitHub canonical → Forgejo canonical in the direction table

## Monitoring gap (known, accepted)

Nothing alerts when a push mirror goes stale. Forgejo logs the failure and shows it in Mirror Settings, but there is no Gatus check or Grafana alert. Detecting staleness requires comparing GitHub's `pushed_at` against now, which Gatus conditions cannot express. Manual spot-check when touching mirror config; automated mirror reconciliation and freshness alerting are deliberately deferred until more than one repo is mirrored.
