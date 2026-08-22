# Forgejo Repository Mirroring

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
| perudo | Forgejo | `github.com/St-John-Software/perudo` | pending — see issue #703 |

Add a row here for every future migration.

## GitHub-side preparation (do this BEFORE creating the mirror)

1. Forgejo push mirrors **force-push** and overwrite the remote. Remove all branch protection rules and rulesets on the GitHub repo's default branch — a protected branch rejects the force push and the mirror silently fails every cycle.
2. Disable GitHub Actions on the mirror (Settings → Actions → General → "Disable actions"). Otherwise every mirror push re-runs CI on GitHub, duplicating builds and Slack failure notifications.
3. Leave Issues enabled but pin/announce that they are read-only; do **not** archive the repo — an archived GitHub repo rejects pushes, which kills the mirror.
4. Update the GitHub repo description/README to point at `https://git.home.bstjohn.net/<owner>/<repo>`.

## Mirror credential

A GitHub **fine-grained** PAT:

- Resource owner `St-John-Software`, scoped to only the repos being mirrored.
- Repository permissions: **Contents: Read and write**. Nothing else. (Add **Workflows: Read and write** only if the mirrored repo contains `.github/workflows/` files that change — GitHub rejects pushes touching workflow files without it. Perudo does have workflows, so grant it.)
- Expiry: 1 year. Record the expiry date and store the token in Vaultwarden (`vaultwarden.home.bstjohn.net`) under an item named `forgejo-push-mirror-github-pat`.
- Trade-off: annual PAT expiry is the exact pain the Forgejo migration is escaping, but for a DR mirror a stale token **fails safe** — the mirror stops updating, the canonical repo is unaffected, and nothing in the cluster breaks. This matches the repo's standing preference for static PATs over dynamic GitHub App auth (see [`ghcr-auth.md`](ghcr-auth.md)).
- The PAT is **not** a Kubernetes Secret and must not be added to `.sops.yaml`-encrypted files — Forgejo stores it in its own DB, encrypted with the instance `SECRET_KEY`.

## Creating the push mirror (UI)

Forgejo repo → Settings → Repository → Mirror Settings → "Add Push Mirror":

- Remote Repository URL: `https://github.com/St-John-Software/<repo>.git`
- Authorization → Username: the GitHub account that owns the PAT (`stjohnb`); Password: the PAT
- Mirror interval: `1h`
- Tick **"Sync when new commits are pushed"**

## Creating the push mirror (API alternative)

Equivalent call, useful for scripting a rebuild:

```
POST https://git.home.bstjohn.net/api/v1/repos/<owner>/<repo>/push_mirrors
Authorization: token <forgejo-api-token>
{
  "remote_address": "https://github.com/St-John-Software/<repo>.git",
  "remote_username": "stjohnb",
  "remote_password": "<github-pat>",
  "interval": "1h",
  "sync_on_commit": true
}
```

List existing mirrors with `GET .../push_mirrors`; delete with `DELETE .../push_mirrors/{name}`.

## Verification

Push a trivial commit to Forgejo, confirm it lands on GitHub within a minute, then check Forgejo → Settings → Mirror Settings shows a recent "Last update" with no error. Also click "Synchronize Now" once and confirm it succeeds.

## Limitations

- LFS objects are not mirrored over SSH (we use HTTPS, but record the caveat).
- The wiki is a separate git repo and is not covered by the code push mirror.
- Issues, PRs, releases metadata, and Actions runs are not mirrored at all — those depend on `forgejo dump` backups.

## PAT rotation

Issue a new fine-grained PAT with the same scopes, then for each mirrored repo edit the push mirror's Authorization password (or `DELETE` + re-`POST` via the API), verify with "Synchronize Now", then revoke the old PAT and update the Vaultwarden item and expiry date. Forgejo does not surface an expiry warning; the first symptom is a stale "Last update".

## Disaster recovery / rebuild

Push-mirror config lives in the Forgejo DB, not in Git. After restoring from a `forgejo dump` backup, verify each mirror still syncs (the `SECRET_KEY` must match or stored passwords will not decrypt). After a *fresh* Forgejo install, re-run the per-repo checklist below.

## Per-repo migration checklist

- [ ] Migrate repo into Forgejo
- [ ] Prep GitHub side (unprotect branch, disable Actions, do not archive)
- [ ] Confirm PAT covers the repo
- [ ] Add the push mirror with `sync_on_commit`
- [ ] Push a test commit and verify on GitHub
- [ ] Add a row to the inventory table in this doc
- [ ] Mark GitHub canonical → Forgejo canonical in the direction table

## Monitoring gap (known, accepted)

Nothing alerts when a push mirror goes stale. Forgejo logs the failure and shows it in Mirror Settings, but there is no Gatus check or Grafana alert. Detecting staleness requires comparing GitHub's `pushed_at` against now, which Gatus conditions cannot express. Manual spot-check at PAT-rotation time; automated mirror reconciliation and freshness alerting are deliberately deferred until more than one repo is mirrored.
