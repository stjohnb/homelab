# Forgejo (Git Forge)

**Depth:** **Reference**
**Read this when:** working on Forgejo storage, upgrades, Actions OIDC, the GitHub-copy policy, or Forgejo-side Renovate.
**Read instead:** [forgejo-backups.md](forgejo-backups.md) for backup and restore procedures.

Self-hosted Git forge (Forgejo, a Gitea fork), used as part of the GitHub-to-Forgejo migration. Single-replica Deployment in the `default` namespace.

## Overview

| Setting | Value |
|---------|-------|
| URL | `https://git.home.bstjohn.net` |
| Image | `registry.home.bstjohn.net/st-john-software/forgejo:15.0.7-5c27263-rootless` — self-built from our patch-and-build repo, see [Self-built image](#self-built-image) |
| Database | PostgreSQL on the shared `apps/postgres` instance — database and role `forgejo`, password in the `forgejo-db-secret` Secret (see [postgres.md](postgres.md) and [Database](#database)) |
| Storage | `local-path` PVC `forgejo-data` (10Gi), mounted at `/var/lib/gitea` |
| SSH | NodePort `30022` → container port `2222` |
| HTTP/Ingress | `traefik-traefik`, `wildcard-home-tls` (see `apps/forgejo/ingress.yaml`) |
| `priorityClassName` | `standard` |
| Update strategy | `Recreate` — the PVC is `ReadWriteOnce` |

Because storage is `local-path`, the pod is pinned to whichever node holds the PVC's underlying volume — there is no `nodeSelector`, the binding comes from the PV itself.

## Configuration

`app.ini` lives on the PVC at `/var/lib/gitea/custom/conf/app.ini` and is regenerated/overlaid from `FORGEJO__<section>__<KEY>` environment variables (`environment-to-ini`) on every container start. This is why the Forgejo 15.0 removal of `/etc/gitea/app.ini` backward compatibility was a non-event here — this deployment already used the new config path under 14.0.3.

`SECRET_KEY` and `INTERNAL_TOKEN` are generated on first boot and persisted in `app.ini` on the PVC — they are **not** stored in Git. Losing the PVC without a backup means losing these along with all repo data.

`environment-to-ini` also writes `FORGEJO__database__PASSWD` into `app.ini` in cleartext, so since the Postgres cutover (#1216) the PVC and every `forgejo dump` archive contain the database password. Treat the archives accordingly.

## Database

Since 2026-09-09 (#1216) Forgejo's database is the `forgejo` database on the shared `apps/postgres` instance rather than an embedded SQLite file. `migrations/0030-forgejo-db.sh` created the `forgejo` role and database, copied the SQLite contents in with `forgejo dump --database postgres`, repaired the serial sequences, and stored the generated password in the `forgejo-db-secret` Secret; the Deployment passes the connection as `FORGEJO__database__*` env. Only the database moved: repositories, LFS objects, SSH host keys, JWT keys and `app.ini` stay on the `forgejo-data` PVC, so the [backup CronJobs](forgejo-backups.md) remain the only backup of that data — `postgres-db-backup` adds a second, independently scheduled copy of the database, nothing more.

- **Bootstrap ordering.** Forgejo now depends on `apps/postgres` being up and on `migrations/0024-postgres-superuser.sh` and `0030-forgejo-db.sh` having run. On a fresh cluster the forge crashloops until the database exists — expected and self-healing, the same shape as the postgres pod's own `CreateContainerConfigError` wait. See [registry.md](registry.md) "Bootstrap ordering" and the runner-image circularity in [forgejo-actions.md](forgejo-actions.md).
- **Rollback.** Reverting the cutover PR is enough while the SQLite file at `/var/lib/gitea/data/gitea.db` is still current. Keep the file — it is ~10 MB and it is the rollback artifact. Once writes have landed in Postgres, going back means `forgejo dump --database sqlite3` and loading its `forgejo-db.sql` into a fresh `gitea.db` per the [restore procedure](forgejo-backups.md#restore-procedure).
- `migrations/0019-forgejo-oidc-auth-source.sh` is one-shot and idempotent and stays `completed:`; the `authentik` auth source travelled with the data and must not be re-created.
- **Loading a `forgejo dump` into Postgres** (what `0030` does, and what the restore procedure repeats): xorm writes the tables in an order that ignores their foreign keys — `access_token_resource_repo`, `collaboration`, `access` and friends reference `repository`, `user`, `access_token` and `issue`, which come later in the file — so a straight `psql -f` stops at the first `relation … does not exist`. Load the `CREATE TABLE` lines in a couple of passes (they are `IF NOT EXISTS`, so re-running them is harmless), then the indexes, then the rows as the superuser under `SET session_replication_role = replica` so row order does not matter either, then repair the serial sequences.

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

Because Forgejo stores auth sources in its database rather than `app.ini`, the source can't be declared as YAML — it's created by `migrations/0019-forgejo-oidc-auth-source.sh`, which execs `forgejo admin auth add-oauth` in the running pod. The migration is idempotent (checks `forgejo admin auth list` first) and retried automatically by the migration Job if the Forgejo pod isn't up yet.

Local password login still works as a fallback for existing accounts — only the local *signup* form is disabled (`FORGEJO__service__ALLOW_ONLY_EXTERNAL_REGISTRATION`), so an Authentik outage does not lock out existing users.

Forgejo's own web sessions are stored in the Forgejo Postgres database (`FORGEJO__session__PROVIDER=db`) with `SESSION_LIFE_TIME=2592000` (30 days). This keeps normal browser sessions alive across pod restarts and avoids the default one-day in-memory session behaviour; if the Forgejo session does expire while the Authentik session is still valid, the OIDC button will still return immediately without showing Authentik pages.

**Rotating the client secret:** patch `FORGEJO_OIDC_CLIENT_SECRET` in the `authentik-secrets` Secret, find the source id via `forgejo admin auth list`, then update Forgejo's DB copy without putting the secret in the exec request URI (#902):

    printf '%s\n' "$NEW_SECRET" | kubectl exec -i -n default "$FORGEJO_POD" -- sh -c \
      'IFS= read -r S; forgejo admin auth update-oauth --id "$1" --secret "$S"' _ "$SOURCE_ID"

## Self-built image

The instance runs an image built by `https://git.home.bstjohn.net/St-John-Software/forgejo`
(canonical and the only live copy; `github.com/St-John-Software/forgejo` is an **archived,
private** read-only snapshot and its push mirror was removed in #1279). Since 2026-09-08 that
repo is **not a fork**: it
is a small patch-and-build repo holding `UPSTREAM_VERSION` (currently `15.0.7`), `patches/`,
`prepare.sh`, `build.sh` and two Forgejo Actions workflows (`ci.yml`, `build-image.yml`).
Upstream is fetched from `https://codeberg.org/forgejo/forgejo.git` at build time, so no
upstream source, branches or tags live in our repo — nothing to prune, and no upstream workflow
can ever run on our runner fleet. The build repo's own `README.md` is the reference for bumping,
regenerating patches and building locally; this section only covers the fleet-infra-facing
parts (tag scheme, receiver workflow, upgrade runbook, break-glass).

The one patch is `[actions] OIDC_ISSUER_URL` (`patches/0001-…`), which lets the Actions ID-token
issuer differ from `ROOT_URL` so a LAN-only instance can present a public issuer whose discovery
document and JWKS are published statically (the same trick as `oidc/` for the k3s API server).
Upstream declined it as too niche (codeberg forgejo#14130).

- **Build:** `prepare.sh` shallow-clones `v$UPSTREAM_VERSION` into a gitignored `upstream/`
  directory (retried 3× for #1194) and applies `patches/*.patch` with
  `git am --committer-date-is-author-date` under a fixed committer identity, so the patched
  commit ids are reproducible. `build.sh` runs `prepare.sh`, then builds upstream's
  **unmodified** `Dockerfile.rootless` with `upstream/` as build context — the build repo does
  not fork the Dockerfile. `ci.yml`'s PR gate is `./prepare.sh` itself, a real `git am`, so a
  `UPSTREAM_VERSION` bump PR goes red exactly when the patch series stops applying; the fix is
  regenerating the patch (build repo README, "Changing the patches"), never editing upstream.
  `build-image.yml` runs on push to `main` (path-filtered to `UPSTREAM_VERSION`, `patches/**`,
  `build.sh`, `prepare.sh`, itself) and on `workflow_dispatch`, on the in-cluster Forgejo Actions
  fleet (`runs-on: [self-hosted, linux]`, see [forgejo-actions.md](forgejo-actions.md)). It
  pushes `registry.home.bstjohn.net/st-john-software/forgejo:<tag>` to the LAN registry
  ([registry.md](registry.md)) and then dispatches fleet-infra's `update-forgejo.yml` with the
  new tag via `gh workflow run`.
- **Runner job image (#1189):** the same repo also builds the Forgejo Actions **job** image
  from `runner-image/Dockerfile` via `.forgejo/workflows/build-runner-image.yml`, pushing
  `registry.home.bstjohn.net/st-john-software/forgejo-runner-nix:YYYYMMDD-HHMM-<sha7>` plus
  `latest` and dispatching fleet-infra's `update-forgejo-runner-nix.yml`. It reuses the same
  job-container gotchas (no docker CLI in the job image, OCI mediatypes, per-run builder name,
  `network=host`) and the same org-level secrets; details in
  [forgejo-actions.md](forgejo-actions.md) and [registry.md](registry.md).
- **Tag scheme:** `<UPSTREAM_VERSION>-<short sha of the build repo>-rootless`, e.g.
  `15.0.7-43831f8-rootless`. Deterministic per commit; validated by `update-forgejo.yml`'s regex
  (`^[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]{7,12}-rootless$`). `build.sh` passes
  `RELEASE_VERSION=<UPSTREAM_VERSION>-<short sha>`. `git describe` and `fetch-depth: 0` are no
  longer used — the version comes from the `UPSTREAM_VERSION` file rather than `git describe` on
  our side, so a shallow clone of the tag is enough.
- **Three versions that differ, and must not be conflated:** the image tag above; the
  `RELEASE_VERSION` build arg / `org.opencontainers.image.version` OCI label,
  `<UPSTREAM_VERSION>-<short sha>` (no `-rootless` suffix); and the version Forgejo itself
  reports (`forgejo --version`, `/api/v1/version`), which upstream's Makefile derives from
  `git describe` inside the patched clone and reads
  `<UPSTREAM_VERSION>-<patch count>-<patched commit sha>+gitea-<compat>`, e.g.
  `15.0.7-1-284eb07+gitea-1.22.0`.
- **Version bumps are ordinary PRs** in the build repo: edit `UPSTREAM_VERSION`, CI reports
  whether the patch series still applies, merge to `main` → `build-image.yml` builds and pushes
  → dispatches fleet-infra's `update-forgejo.yml`, which opens the bump PR here for manual review
  and merge (see the Upgrade Runbook below — unlike the other `update-*.yml` receivers, this PR
  does not carry the `auto-bump` label). Renovate on `UPSTREAM_VERSION` against Codeberg releases
  is the longer-term source of that bump PR (#1168).
- **Build-repo secrets:** org-level Forgejo Actions secrets on `St-John-Software`
  (`REGISTRY_USER`/`REGISTRY_PASSWORD` = the `ci` identity, see [registry.md](registry.md)
  "Logging in from a workstation"; `FLEET_INFRA_VERSION_BUMP` for the dispatch) — the build repo
  has no secrets of its own. `docker login --password-stdin` only; the credential must never
  appear in argv on a shared runner.
- **Job-container gotchas** `build-image.yml` works around:
  - The job image (`forgejo-runner-nix`) ships **no docker CLI**, but the dind sidecar's socket
    is bind-mounted at `/var/run/docker.sock`. The workflow brings its own CLI, buildx plugin
    and `gh` from nix.
  - zot answers `manifest invalid` to Docker-format manifests, so the push must be OCI:
    `--output type=image,oci-mediatypes=true,push=true` on a `docker-container` buildx builder.
    (The `docker` driver cannot push attestations at all.)
  - The dind sidecar outlives the job, so a buildx builder container created with a fixed name
    is still there on the next run. The workflow names the builder `forgejo-<run id>` and
    removes it in an `if: always()` step.
  - Build steps on dind's `docker0` bridge sit behind a second NAT layer, and apk fetches from
    the Alpine CDN stalled mid-transfer there. The builder is created with
    `--driver-opt network=host`, which puts it on the pod network instead.
- **New watch-out:** the build clones from Codeberg at build time, so the k3s-node runner's
  outbound-connection stalls (#1194) and Codeberg's anonymous rate limits apply — `prepare.sh`
  retries the clone 3×; prefer the ryzen / k3s-nas runners if a run still flakes.
- **Fleet-infra side:** `.github/workflows/update-forgejo.yml` receives the dispatch, validates
  the tag, and opens the `automation/bump-forgejo-<tag>` PR bumping both
  `apps/forgejo/deployment.yaml` and `apps/forgejo/cronjob-backup.yaml`.
- **Pull:** both `apps/forgejo/deployment.yaml` and `apps/forgejo/cronjob-backup.yaml` reference
  the LAN registry, so both carry `imagePullSecrets: registry-pull`.
- **Break-glass:** if Forgejo is down its own Actions cannot build, and on a cluster rebuild the
  registry PVC is empty too. The escape: clone the small build repo — first choice a local clone
  if one exists, else the archived GitHub snapshot `github.com/St-John-Software/forgejo` (private
  + archived since 2026-09-10, so authenticated and possibly stale — its push mirror was deleted
  in #1279), else the nightly dump: power on the NAS, take the newest
  `/mnt/SSD-POOL/media/backups/forgejo/forgejo-dump-*.tar.gz` (see
  [forgejo-backups.md](forgejo-backups.md)) and extract `repos/st-john-software/forgejo.git` from
  it. Clone onto any machine with docker + buildx that can reach Codeberg and the registry, and
  run `PUSH=1 ./build.sh`; or use a one-off privileged
  `moby/buildkit:v0.29.0` Job on the `k3s` node, keeping `oci-mediatypes=true` in `buildctl`'s
  `--output` (without it zot answers `manifest invalid`). The upstream
  `codeberg.org/forgejo/forgejo:15.0.x-rootless` image remains a valid emergency substitute for
  the server image — it only lacks `OIDC_ISSUER_URL`, which it ignores. The same BuildKit Job
  path covers `runner-image/Dockerfile` too, with no equivalent upstream substitute — see the
  runner-image circularity documented in [forgejo-actions.md](forgejo-actions.md) and the
  bootstrap order in [registry.md](registry.md) "Bootstrap ordering".

The layout above has been live since 2026-09-08 (build-repo commit `43831f8`); the
pre-restructure fork history is preserved in an off-repo `git bundle` and is not needed —
upstream lives on Codeberg and the patch is `patches/0001`.

## GitHub copies (mirrors retired)

**Policy: there are no new Forgejo → GitHub push mirrors, and a migrated repo's GitHub
repository is archived, not mirrored.** Decision 2026-09-10 (#1279), reversing #1176. A migrated
repo is canonical on `git.home.bstjohn.net`; its GitHub repository is flipped **private and
archived** (read-only) so the imported issue history stays browsable, and its push mirror and
write-enabled deploy key are deleted. GitHub copies are never deleted outright.

Why the mirrors went:

- Every consumer had to carry "GitHub is a stale mirror" special-casing — Claws' repo discovery
  and its cold-start exclusion floor (the mirrored `claws.json` said "automate me"),
  `open-pull-requests-limit: 0` Dependabot caps on each mirror, and the GitHub-side constraints
  the mirror itself imposed (branch protection off, Actions disabled, and the repo could *not*
  be archived, because archiving rejects the mirror's force-push). Archiving is only possible
  once the mirror is gone.
- The stated purpose was DR ("the cluster is down and I need the code now"). The nightly
  `forgejo dump` covers that and is the only copy that also carries issues, PRs, users and
  settings — extract `repos/<owner>/<repo>.git` from the tarball and clone it. See
  [forgejo-backups.md](forgejo-backups.md). No separate git-cloneable backup tree is wanted.

Server-side enforcement is in `apps/forgejo/deployment.yaml`: `FORGEJO__mirror__ENABLED` is
`"false"` (#1296), so the mirror subsystem is off entirely, and `FORGEJO__mirror__DISABLE_NEW_PULL`
and `FORGEJO__mirror__DISABLE_NEW_PUSH` both stay `"true"` so the policy still holds if `ENABLED`
is ever flipped back.

### Decommissioning status

**No push or pull mirrors exist on this instance.** The last one, perudo's push mirror to
`github.com/St-John-Software/perudo` (`remote_mirror_3jQFG1f1Nfe`, GitHub deploy key 161463629),
was deleted on 2026-09-10 (#1296) after [perudo#307](https://git.home.bstjohn.net/St-John-Software/perudo/issues/307)
moved its AWS deploy and infra jobs onto Forgejo Actions OIDC; bin-scraper's and the forgejo build
repo's went on the same day (#1279). Every GitHub copy of a migrated repo (perudo, bin-scraper,
forgejo) is now private and archived — read-only, frozen at its last mirrored commit. `cycling`
never had a GitHub copy. The only off-node copy of repo content is the nightly `forgejo dump` on
the NAS ([forgejo-backups.md](forgejo-backups.md)), which is also the only copy of issues, PRs,
users and settings.

Removing a mirror: Forgejo repo → Settings → Repository → Mirror Settings, or as a repo admin
`DELETE /api/v1/repos/{owner}/{repo}/push_mirrors/{name}` (the `clawsstjohn` token gets 403 on
`push_mirrors`). Then delete the write-enabled deploy key on GitHub (Settings → Deploy keys) and
archive the GitHub repo. The mirror's SSH private key lives in Forgejo's DB encrypted with the
instance `SECRET_KEY`; it is never a Kubernetes Secret, so nothing needs cleaning up in Git.

### Per-repo migration checklist

- [ ] Migrate the repo into Forgejo ("Migrate Repository" *without* the mirror checkbox — a
      one-shot migration is not a pull mirror and is unaffected by `DISABLE_NEW_PULL`)
- [ ] Port CI to `.forgejo/workflows/` and confirm it is green
- [ ] Archive the GitHub repository (private + archived, read-only)
- [ ] Add the repo to the `repositories` list in `apps/renovate/configmap.yaml`
- [ ] Do **not** create a push mirror or a GitHub deploy key

## Claws bot accounts

Claws holds two Forgejo identities, both declared by
`migrations/0034-claws-forgejo-accounts.sh` — the accounts, their org team memberships and their
tokens all come from that one migration, so nothing here is provisioned by hand:

- **`clawsstjohn`** — org team **`claws-bot`** (write, all repositories). This is the implicit
  credential in every Forgejo session Claws runs.
- **`claws-admin`** — org team **`Owners`**. Used only for the opt-in `forgejo-admin` capability
  (Actions secrets and variables, which need org-owner rights); see claws#2965.

**Neither account is a site admin**, unlike `renovate` above. Tokens land in the Secret
`claws-forgejo-tokens` in `default`:

| Key | Account | Token name | Scopes |
|-----|---------|-----------|--------|
| `service-token` | `clawsstjohn` | `claws-k8s` | `write:repository,write:issue,read:user` |
| `admin-token` | `claws-admin` | `claws-admin-k8s` | `write:repository,write:organization` |

`apps/claws/statefulset-staging.yaml` consumes them as `CLAWS_FORGEJO_TOKEN` and
`CLAWS_FORGEJO_ADMIN_TOKEN` (both `optional: true` on the key ref, so the manifests reconcile
green before the migration has run). Those two variable names are the cross-repo contract with
claws#2965 — changing either side needs both.

**The throwaway-admin technique.** Forgejo has no `forgejo admin team` CLI, and adding a
non-admin user to a team needs an org-owner credential that a migration does not have. 0034
therefore creates a site-admin user `migration-0034`, mints it a token scoped
`write:organization,read:organization`, resolves the two team ids from
`GET /api/v1/orgs/St-John-Software/teams`, calls `PUT /api/v1/teams/{id}/members/{username}` for
each pair, then deletes the user — an `EXIT` trap covers the failure paths. Deleting the user
drops its token, so no owner-level credential survives the run. This is preferred over 0032's
permanent site-admin bot because `clawsstjohn`'s token is implicit in every Forgejo session and so
reaches agents processing untrusted issue and PR content. The whole sequence runs inside a single
in-pod `sh -c`, so no token is ever a `kubectl exec` argument (#902). `forgejo admin user delete`
is called without `--purge`, which would also delete repositories and organizations.

**Re-minting carries the same caveat as Renovate.** If `claws-forgejo-tokens` is deleted, 0034
cannot re-mint under the same token names until the stale `claws-k8s` / `claws-admin-k8s` tokens
are deleted first (user → Settings → Applications). Token deletion is UI-only; there is no CLI
counterpart.

`claws-admin` must never appear in Claws' `allowedActors`, so its comments and reviews can never
count as an LGTM. The host-side `claws-service` token on `clawsstjohn` is untouched by this
migration and retires with the automation host (revocation is UI-only, same constraint as
claws#2672 for `brendan`).

## Dependency updates (Renovate)

Dependency updates for repos that live on Forgejo come from a **second, independent Renovate
instance** that runs only against Forgejo:

- The in-cluster weekly CronJob `renovate` (`apps/renovate/`), Mondays 07:00 Europe/London,
  `platform: forgejo` against `https://git.home.bstjohn.net/api/v1`. This is separate from
  `.github/workflows/renovate.yml`, which stays scoped to fleet-infra itself on GitHub — the two
  share no token and no config (see
  [infrastructure-overview.md](infrastructure-overview.md#automated-dependency-updates)).
- **Covered repos = the `repositories` array in `apps/renovate/configmap.yaml`.** Adding the next
  migrated repo means adding one line there — no new automation.
- The bot is a site-admin Forgejo user `renovate`, created by
  `migrations/0032-renovate-forgejo-token.sh` with a token scoped
  `write:repository,write:issue,read:user,read:organization` — no admin scope, so the token itself
  cannot reach any Forgejo admin API even though the account is a site admin. If the
  `renovate-forgejo-token` Secret is ever deleted, the migration cannot re-mint a token under the
  same name until the stale `renovate-k8s` token is deleted first (`renovate` user → Settings →
  Applications) — Forgejo token names are unique per user. This is a general CLI limitation, not
  specific to renovate: `forgejo admin user generate-access-token` (used by migration scripts to
  mint tokens from inside the pod) has no delete counterpart — `forgejo admin user --help` lists
  no `delete-access-token` subcommand — so revoking or renaming any Forgejo-minted token always
  needs the web UI (Settings → Applications) or a basic-auth API call, never a CLI one-liner.
- `automerge` is off in `apps/renovate/configmap.yaml` until Forgejo branch protection with
  required status checks exists on the covered repos — Forgejo's "merge when checks succeed"
  merges immediately on a repo with no required checks configured. Once that's in place,
  Forgejo-native automerge is the mechanism (Claws does not poll Forgejo).
- Optional: create a read-only `github.com` PAT (no scopes) so changelog/release-note lookups
  aren't limited to 60 anonymous req/h:
  `kubectl create secret generic renovate-github-com -n default --from-literal=token=<classic PAT, no scopes>`.
  Its absence produces warnings, not failures.
- Run on demand: `kubectl create job -n default --from=cronjob/renovate renovate-manual` then
  `kubectl logs -n default job/renovate-manual`.

## Upgrade Runbook

1. Open a PR in `St-John-Software/forgejo` bumping `UPSTREAM_VERSION` (review the release's breaking-changes notes). CI runs `prepare.sh`; green means the patch series still applies, red means regenerate the patch (build-repo README, "Changing the patches"). Merge to `main` — `build-image.yml` builds, pushes `registry.home.bstjohn.net/st-john-software/forgejo:<version>-<sha>-rootless`, and dispatches fleet-infra's `update-forgejo.yml`. Confirm the tag with `GET https://registry.home.bstjohn.net/v2/st-john-software/forgejo/tags/list` using the `ci` credential.
2. `update-forgejo.yml` opens the `automation/bump-forgejo-<tag>` PR here, updating **both** `apps/forgejo/deployment.yaml` **and** `apps/forgejo/cronjob-backup.yaml` — they must always match, because `forgejo dump` reads the database with the schema its own binary expects, so a stale backup image fails outright once the server has migrated (a 14.0.3 dump against a 15.0.5 DB fails with `no such column: remote_address`). `task validate`'s `check-image-consistency` step fails on a mismatch. This PR does not carry the `auto-bump` label — Claws reviews it, but nobody merges it automatically. Work through the pre-merge checklist in the PR body: read the release notes, and if they warn of a long migration, widen `startupProbe.failureThreshold` on the branch as a follow-up commit before approving.
3. Take a manual dump before merging and store it off-cluster — run the Stage 1 backup job on demand (see "Manual runs" in [docs/forgejo-backups.md](forgejo-backups.md)) rather than a bespoke `forgejo dump` command, so the pre-upgrade backup is verified the same way as the nightly ones. The last successful `postgres-db-backup` run (`/media/backups/postgres/forgejo/*.pgdump`) is a second pre-upgrade artefact for the database, but Stage 1 remains the required one: only it covers the repositories.
4. LGTM and merge. Flux reconciles in ~1 min; `Recreate` terminates the old pod before starting the new one, so expect a brief outage.
5. Watch `kubectl get pods -l app=forgejo -w` and `kubectl logs -f -l app=forgejo` — expect DB migration log lines followed by `Starting server on :3000`.
6. Verify: `curl -sk https://git.home.bstjohn.net/api/v1/version` returns `<upstream version>-<patch count>-<patched sha>+gitea-<compat>` (e.g. `15.0.7-1-284eb07+gitea-1.22.0`), **not** the image tag — a mismatch between that string and the tag is expected, not a failed rollout. `kubectl exec -n default deploy/forgejo -- forgejo doctor check --all` reports no errors.
7. Confirm the Gatus check (`apps/gatus/config.yaml`, `https://git.home.bstjohn.net/api/healthz`) and the homepage tile (`apps/homepage/config/services.yaml`) are still green.

**Rollback:** Reverting the deployment PR is only safe *before* the new version has migrated the database. Once the pod comes up healthy on the new version and serves traffic, a downgrade requires restoring the pre-upgrade dump onto a fresh PVC — Forgejo does not support backward DB migrations.

**Known post-upgrade behaviour (15.0):** Cookie names became brand-independent, so all users must re-login once after the upgrade. This is expected and not a bug.

## Actions OIDC (available from 15.0)

Forgejo Actions workflows/jobs can opt into minting a short-lived OIDC ID token to exchange with a cloud provider (e.g., for perudo's AWS deploy):

- Issuer: `https://www.bstjohn.net/forgejo-oidc` (public; set by `FORGEJO__actions__OIDC_ISSUER_URL` in `apps/forgejo/deployment.yaml`)
- Subject: `repo:<owner>/<repo>:ref:<ref>` for most events, `repo:<owner>/<repo>:pull_request` for pull request events
- Claims include `actor`, `event_name`, `ref`, `repository`, `sha`, `workflow`

OIDC is not enabled globally — it must be opted into per workflow or per job. When enabled, the runner injects `ACTIONS_ID_TOKEN_REQUEST_URL` and `ACTIONS_ID_TOKEN_REQUEST_TOKEN` into the job environment, and a token is fetched with:

```bash
curl -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=<aud>"
```

**Prerequisite:** OIDC requires Forgejo Runner > 12.5 — satisfied by the in-cluster runner (`code.forgejo.org/forgejo/runner:12.13.2`, `apps/forgejo-runner/`). See [docs/forgejo-actions.md](forgejo-actions.md) for the runner architecture and registration procedure.

### Public issuer and discovery documents

Upstream declined to decouple the Actions OIDC issuer from `ROOT_URL` (codeberg forgejo#14130, filed 2026-08-27), so our fork carries an `[actions] OIDC_ISSUER_URL` patch — see "Self-built image" and https://git.home.bstjohn.net/St-John-Software/forgejo/pulls/1. `ROOT_URL` stays `https://git.home.bstjohn.net/` (load-bearing for Authentik SSO callbacks and clone URLs); only the OIDC issuer moves.

| Property | Value |
|----------|-------|
| Issuer URL | `https://www.bstjohn.net/forgejo-oidc` (no trailing slash) |
| Discovery document | `https://www.bstjohn.net/forgejo-oidc/.well-known/openid-configuration` |
| JWKS | `https://www.bstjohn.net/forgejo-oidc/.well-known/keys` |
| Source of truth | Forgejo's live `/api/actions/.well-known/*` on `git.home.bstjohn.net` |
| Publisher | `.github/workflows/publish-forgejo-oidc.yml` (`workflow_dispatch` only — nothing publishes on merge) |
| Live since | 2026-09-10 — first and only dispatch to date (Actions run `34464278940`) |

The setting takes effect only on the forked image; upstream ignores it. It must be an absolute `https` URL with no credentials, query or fragment (a trailing slash is stripped); an invalid value fails startup, and the deployment uses `Recreate`, so a bad value is an outage.

Forgejo keeps serving the real keys at `https://git.home.bstjohn.net/api/actions/.well-known/keys`; the public URL is a mirrored copy, so **re-dispatch the publish workflow whenever the Actions JWT signing key rotates or Forgejo is upgraded**. The workflow refuses to upload if the served `issuer` is not the public one, so it cannot publish a LAN issuer by mistake. Only `issuer` and `jwks_uri` are rewritten by the patch; the other endpoints in the document still point at the LAN host, which is fine — IAM reads only those two.

`forgejo-oidc/` is a fleet-infra-owned prefix of the `www.bstjohn.net` bucket under the same folder-ownership convention as `k3s-oidc/` — see [infrastructure-overview.md](infrastructure-overview.md#cluster-oidc-discovery).

**Publishing is manual and started on 2026-09-10.** The workflow has no `push` trigger, so merging a change here publishes nothing — the documents exist only because it was dispatched by hand. It was deliberately left undispatched until the S3 permissions were in place: the `AWS_OIDC_PUBLISH_ROLE_ARN` role's policy originally covered only `k3s-oidc/*`, so a dispatch before then would have failed at `aws s3 cp` with `AccessDenied`. `St-John-Software/bstjohn-blog` PR #710 (issue #709, merged 2026-09-09) added `arn:aws:s3:::www.bstjohn.net/forgejo-oidc/*` to that policy and `--exclude "forgejo-oidc/*"` to the blog's `aws s3 sync … --delete` (without which the next blog deploy would delete the published documents and break every Forgejo→AWS federation). The first — and so far only — run is `34464278940`, dispatched 2026-09-10; the discovery document and JWKS have been publicly resolvable from then on.

**Verify after a change:**

```bash
curl -s https://git.home.bstjohn.net/api/actions/.well-known/openid-configuration | jq .issuer
curl -s https://www.bstjohn.net/forgejo-oidc/.well-known/openid-configuration | jq .
diff <(curl -s https://git.home.bstjohn.net/api/actions/.well-known/keys | jq -S .) \
     <(curl -s https://www.bstjohn.net/forgejo-oidc/.well-known/keys | jq -S .)
```

A workflow that requests an ID token must then see `iss` equal to the public issuer.

### Consumer setup

Consumers — one AWS IAM OIDC provider plus role trust policies per consuming AWS account — are set up per consumer and are not managed from this repo.

**perudo (live since 2026-09-10, the first and only consumer).** perudo deploys and applies infra from **Forgejo Actions**, authenticating to AWS with this issuer via `aws-actions/configure-aws-credentials` and `role-to-assume` — no static AWS access keys anywhere in that pipeline. perudo#307 (PRs #308 and #309) added the `www.bstjohn.net/forgejo-oidc` IAM provider alongside the GitHub one, cut the workflows over to `.forgejo/workflows/`, then removed the `token.actions.githubusercontent.com` trust from `perudo-github-actions-deploy`, `perudo-github-actions-infra-plan` and `perudo-github-actions-infra-apply`. The first Forgejo-run `Deploy to S3` and `Infrastructure` apply on `main` (merge `810304a`) both succeeded. `.github/workflows/deploy.yml` and `infra.yml` are deleted from the repo, the GitHub copy is archived, and its push mirror is gone (#1296) — GitHub can no longer deploy perudo even if a workflow were re-added. perudo#212 proposed static scoped keys as one option; it was closed unimplemented on 2026-09-09.

**Shape of a consumer, for any repo that wants to use this issuer.** Copy perudo's GitHub-OIDC blocks and swap the issuer:

```hcl
resource "aws_iam_openid_connect_provider" "forgejo" {
  url            = "https://www.bstjohn.net/forgejo-oidc"   # exactly the issuer, no trailing slash
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "forgejo_actions_trust" {
  statement {
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.forgejo.arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "www.bstjohn.net/forgejo-oidc:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "www.bstjohn.net/forgejo-oidc:sub"
      values   = ["repo:St-John-Software/<repo>:ref:refs/heads/main"]
    }
  }
}
```

- The IAM condition-key prefix is the issuer **with the scheme stripped**, host *and* path: `www.bstjohn.net/forgejo-oidc:aud` / `:sub` — not just the hostname. Getting this wrong yields `Not authorized to perform sts:AssumeRoleWithWebIdentity` with no further detail.
- `:sub` values use the formats in "Actions OIDC" above: `repo:<owner>/<repo>:ref:<ref>` for most events (e.g. `repo:St-John-Software/perudo:ref:refs/heads/main`), and `repo:<owner>/<repo>:pull_request` for pull-request events. Split plan/apply roles the way perudo does: `pull_request` for the read-only role, `refs/heads/main` for the writing one.
- The provider ARN is deterministic — `arn:aws:iam::<account>:oidc-provider/www.bstjohn.net/forgejo-oidc` — so a role in a second stack can reference it without `iam:ListOpenIDConnectProviders`.
- No thumbprint is needed: the endpoint is served by CloudFront with a public-CA certificate, and AWS validates those itself.
- On the workflow side the job must opt into OIDC (off by default, per-workflow or per-job) and request `audience=sts.amazonaws.com`.
- **Chicken-and-egg: the first apply for a repo cannot come from the pipeline it is enabling.** Creating the OIDC provider and the roles needs credentials that already exist — a workstation admin profile, or the repo's existing GitHub-Actions OIDC apply role if its policy is widened first. perudo's scoped `infra-apply` policy carries only `iam:GetOpenIDConnectProvider` on the existing provider (`ReadOidcProvider`), so it cannot create a new one; perudo gates creation behind a `create_oidc_provider` variable for exactly this reason. Plan for one privileged bootstrap apply, then hand the stack back to CI.

## Ephemeral Runners

15.0 also adds ephemeral runner registration: a runner registers for a single job and its credentials are invalidated immediately after, rather than staying registered indefinitely. The in-cluster runner still registers persistently (`migrations/0017-forgejo-runner-secret.sh` has no `--ephemeral` flag) — see "Known gaps" in [docs/forgejo-actions.md](forgejo-actions.md) for why.
