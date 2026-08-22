# Forgejo (Git Forge)

Self-hosted Git forge (Forgejo, a Gitea fork), used as part of the GitHub-to-Forgejo migration. Single-replica Deployment in the `default` namespace.

## Overview

| Setting | Value |
|---------|-------|
| URL | `https://git.home.bstjohn.net` |
| Image | `codeberg.org/forgejo/forgejo:15.0.5-rootless` |
| Database | SQLite at `/var/lib/gitea/data/gitea.db` (WAL mode) |
| Storage | `local-path` PVC `forgejo-data` (10Gi), mounted at `/var/lib/gitea` |
| SSH | NodePort `30022` → container port `2222` |
| HTTP/Ingress | `traefik-traefik`, `wildcard-home-tls` (see `apps/forgejo/ingress.yaml`) |
| `priorityClassName` | `standard` |
| Update strategy | `Recreate` — the PVC is `ReadWriteOnce` and SQLite must not have two writers |

Because storage is `local-path`, the pod is pinned to whichever node holds the PVC's underlying volume — there is no `nodeSelector`, the binding comes from the PV itself.

## Configuration

`app.ini` lives on the PVC at `/var/lib/gitea/custom/conf/app.ini` and is regenerated/overlaid from `FORGEJO__<section>__<KEY>` environment variables (`environment-to-ini`) on every container start. This is why the Forgejo 15.0 removal of `/etc/gitea/app.ini` backward compatibility was a non-event here — this deployment already used the new config path under 14.0.3.

`SECRET_KEY` and `INTERNAL_TOKEN` are generated on first boot and persisted in `app.ini` on the PVC — they are **not** stored in Git. Losing the PVC without a backup means losing these along with all repo data.

## Authentik SSO

Forgejo authenticates against Authentik via a native OAuth2/OIDC auth source (not the legacy `/user/login/openid` OpenID 2.0 form, which is disabled — see below).

| Setting | Value |
|---------|-------|
| Auth source name | `authentik` |
| Client ID | `forgejo` |
| Callback URL | `https://git.home.bstjohn.net/user/oauth2/authentik/callback` |
| Discovery URL | `https://auth.home.bstjohn.net/application/o/forgejo/.well-known/openid-configuration` |
| Admin group | `infra` (Authentik group `infra` maps to Forgejo admin) |
| Required Authentik group | `all-apps` or `infra` |

Because Forgejo stores auth sources in its SQLite DB rather than `app.ini`, the source can't be declared as YAML — it's created by `migrations/0019-forgejo-oidc-auth-source.sh`, which execs `forgejo admin auth add-oauth` in the running pod. The migration is idempotent (checks `forgejo admin auth list` first) and retried automatically by the migration Job if the Forgejo pod isn't up yet.

Local password login still works as a fallback for existing accounts — only the local *signup* form is disabled (`FORGEJO__service__ALLOW_ONLY_EXTERNAL_REGISTRATION`), so an Authentik outage does not lock out existing users.

**Rotating the client secret:** patch `FORGEJO_OIDC_CLIENT_SECRET` in the `authentik-secrets` Secret, then run `forgejo admin auth update-oauth --id <n> --secret <new>` in the Forgejo pod (find `<n>` via `forgejo admin auth list`) so Forgejo's DB copy matches.

## Upgrade Runbook

1. Confirm the target rootless tag exists on the Codeberg registry and review the release's breaking-changes notes.
2. Take a manual dump before upgrading and store it off-cluster — run the Stage 1 backup job on demand (see "Manual runs" in [docs/forgejo-backups.md](forgejo-backups.md)) rather than a bespoke `forgejo dump` command, so the pre-upgrade backup is verified the same way as the nightly ones.
3. Bump the image tag in **both** `apps/forgejo/deployment.yaml` **and** `apps/forgejo/cronjob-backup.yaml` — they must always match, because `forgejo dump` reads the database with the schema its own binary expects, so a stale backup image fails outright once the server has migrated (a 14.0.3 dump against a 15.0.5 DB fails with `no such column: remote_address`). Widen `startupProbe.failureThreshold` if the release notes call out a longer migration, open a PR, run `task validate` — its `check-image-consistency` step fails on a mismatch.
4. Merge. Flux reconciles in ~1 min; `Recreate` terminates the old pod before starting the new one, so expect a brief outage.
5. Watch `kubectl get pods -l app=forgejo -w` and `kubectl logs -f -l app=forgejo` — expect DB migration log lines followed by `Starting server on :3000`.
6. Verify: `curl -sk https://git.home.bstjohn.net/api/v1/version` returns the new version, and `kubectl exec -n default deploy/forgejo -- forgejo doctor check --all` reports no errors.
7. Confirm the Gatus check (`apps/gatus/config.yaml`, `https://git.home.bstjohn.net/api/healthz`) and the homepage tile (`apps/homepage/config/services.yaml`) are still green.

**Rollback:** Reverting the deployment PR is only safe *before* the new version has migrated the database. Once the pod comes up healthy on the new version and serves traffic, a downgrade requires restoring the pre-upgrade dump onto a fresh PVC — Forgejo does not support backward DB migrations.

**Known post-upgrade behaviour (15.0):** Cookie names became brand-independent, so all users must re-login once after the upgrade. This is expected and not a bug.

## Actions OIDC (available from 15.0)

Forgejo Actions workflows/jobs can opt into minting a short-lived OIDC ID token to exchange with a cloud provider (e.g., for perudo's AWS deploy):

- Issuer: `https://git.home.bstjohn.net/api/actions`
- Subject: `repo:<owner>/<repo>:ref:<ref>` for most events, `repo:<owner>/<repo>:pull_request` for pull request events
- Claims include `actor`, `event_name`, `ref`, `repository`, `sha`, `workflow`

OIDC is not enabled globally — it must be opted into per workflow or per job. When enabled, the runner injects `ACTIONS_ID_TOKEN_REQUEST_URL` and `ACTIONS_ID_TOKEN_REQUEST_TOKEN` into the job environment, and a token is fetched with:

```bash
curl -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=<aud>"
```

**Prerequisite:** OIDC requires Forgejo Runner > 12.5 — satisfied by the in-cluster runner (`code.forgejo.org/forgejo/runner:12.13.2`, `apps/forgejo-runner/`). See [docs/forgejo-actions.md](forgejo-actions.md) for the runner architecture and registration procedure.

## Ephemeral Runners

15.0 also adds ephemeral runner registration: a runner registers for a single job and its credentials are invalidated immediately after, rather than staying registered indefinitely. The in-cluster runner still registers persistently (`migrations/0017-forgejo-runner-secret.sh` has no `--ephemeral` flag) — see "Known gaps" in [docs/forgejo-actions.md](forgejo-actions.md) for why.
