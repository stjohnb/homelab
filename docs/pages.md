# Pages: private CI previews and rendered docs

**Reference**

**Read this when:** publishing a CI preview or rendered docs from a repo, onboarding a new repo to the pages host, rotating its credential, or working on `apps/garage/`.

`pages.home.bstjohn.net` is a private static-hosting location. Any CI workflow — GitHub Actions on the self-hosted runners, Forgejo Actions on the in-cluster runners — or Claws can push a directory of HTML, SVG and PNG to it and link to it from a PR comment or issue page. It fills the gap left by 3d-models' public `www.bstjohn.net` S3 bucket, which stays the right place for public galleries but not for private repos.

## What it is

A single-node [Garage](https://garagehq.deuxfleurs.fr/) S3-compatible object store (`apps/garage/`, `dxflrs/garage:v2.4.1`) with one bucket, `pages`, in website mode. Garage is also the intended object store for Garden photos and backups (#1006/#1010); `pages` is its first tenant.

| Host | Backend | Auth | Used by |
| --- | --- | --- | --- |
| `pages.home.bstjohn.net` | Garage web endpoint (`garage:3902`) | Authentik ForwardAuth (`infra` + `all-apps` groups) | Browsers |
| `s3.home.bstjohn.net` | Garage S3 API (`garage:3900`) | SigV4 with the `pages-publisher` key; no ForwardAuth | CI publishers |

Both hosts are `.home` only: LAN, and the tailnet via split DNS. There is no `.ext` host and nothing public. `garage-ingress-restricted` (`apps/garage/networkpolicy.yaml`) admits the web port from Traefik only, so ForwardAuth cannot be bypassed from inside the cluster. In-cluster publishers (Claws, `pages-janitor`) reach the S3 API directly at `http://garage.default.svc.cluster.local:3900`.

The S3 API is **path-style only** (`https://s3.home.bstjohn.net/pages/<key>`). Virtual-host style would need `pages.s3.home.bstjohn.net`, which the wildcard certificate cannot cover, so every client must set `addressing_style = path`. The S3 region is `garage`.

Garage's web endpoint has no directory listing: a URL resolves only if its prefix holds an `index.html`. Every publish must include one at its root.

## Path convention

```
https://pages.home.bstjohn.net/<repo>/<kind>/<ref>/<sha8>/
```

| Segment | Value |
| --- | --- |
| `<repo>` | Lowercase repo name without the owner (`ha-carlink`, not `St-John-Software/ha-carlink`) |
| `<kind>` | `pr`, `issue` or `docs` |
| `<ref>` | `pr-<N>` for `pr`; the issue id (`123` or `clw_…`) for `issue`; the branch name with `/` replaced by `-` for `docs` |
| `<sha8>` | First 8 characters of the commit SHA, lowercase |

Examples:

- PR preview: `https://pages.home.bstjohn.net/ha-carlink/pr/pr-42/1a2b3c4d/`
- PR-less issue preview: `https://pages.home.bstjohn.net/ha-carlink/issue/clw_01M3HGCWXZEVDX7AC95YZGQ3F1/1a2b3c4d/`
- Rendered main-branch docs: `https://pages.home.bstjohn.net/ha-carlink/docs/main/1a2b3c4d/`

The URL is fully determined by the repo, event and SHA, so a workflow can construct it before the upload finishes. Keys never contain whitespace.

## Backup and disposability

The whole `garage-data` PVC (`local-path`, 50Gi, pinned to the `k3s` node) is **disposable and not backed up**:

- `pr` and `issue` content is throwaway review material; losing it only means re-running the preview job.
- `docs` content is reproducible: re-run the repo's publishing workflow on its main branch.

A lost node disk therefore loses nothing that cannot be regenerated from Git. If a future tenant (Garden photos) stores irreplaceable data in Garage, this classification must be revisited for that tenant.

## Size cap

The `pages` bucket has a hard quota of 20 GiB (`maxSize` 21474836480 bytes, set by migration `0042`). A runaway render fails its own upload once the bucket is full; the node and every other workload are unaffected, and the PVC's 50Gi leaves headroom. A quota failure surfaces as an error on the `PutObject` call in the workflow log, of this shape (exact wording is Garage's):

```
upload failed: ./preview/board.svg to s3://pages/ha-carlink/pr/pr-42/1a2b3c4d/board.svg
An error occurred (...) when calling the PutObject operation: ... quota ...
```

The fix is cleanup (below), or a smaller publish — not raising the quota past what the PVC can hold. `local-path` cannot expand a volume.

## Cleanup

Three layers:

1. **Supersession (in the publish step).** After a successful sync of `<repo>/<kind>/<ref>/<sha8>/`, the same step deletes every sibling SHA under `<repo>/<kind>/<ref>/`. Only the latest SHA for a PR, issue or branch is ever served.
2. **PR close (per repo).** A `pages-cleanup` workflow in each consuming repo deletes `<repo>/pr/pr-<N>/` when the PR closes, merged or abandoned.
3. **Janitor (in-cluster).** The `pages-janitor` CronJob (`apps/garage/cronjob-janitor.yaml`, Mondays 04:15 Europe/London) deletes `pr` and `issue` objects last modified more than 30 days ago, catching orphans from a missed close event or a deleted repo. `docs` objects never expire. Run it on demand with `kubectl create job --from=cronjob/pages-janitor pages-janitor-manual`.

## The credential

One Garage key, `pages-publisher` (read/write/owner on `pages`), minted by `migrations/0042-pages-bucket.sh` and stored in Secret `pages-s3-credentials` in `default` (keys `access-key-id`, `secret-access-key`, `endpoint`, `bucket`). It is never in Git.

| Consumer | Where it reads the key |
| --- | --- |
| GitHub Actions | Org-level Actions secrets `PAGES_S3_ACCESS_KEY_ID` / `PAGES_S3_SECRET_ACCESS_KEY` on `St-John-Software` |
| Forgejo Actions | The same two names as org-level Actions secrets on the Forgejo `St-John-Software` org |
| Claws | `CLAWS_PAGES_S3_ACCESS_KEY_ID` / `CLAWS_PAGES_S3_SECRET_ACCESS_KEY` from `pages-s3-credentials` in `clusters/my-cluster/claws/statefulset.yaml` (unused until Claws follow-up `#clw_01M3J52H0H9WSH3GTSY87ZY351` lands) |
| `pages-janitor` | `pages-s3-credentials` directly |

Because every repo reads org-level secrets by the same names, rotation never edits a consuming repo's workflow. If the GitHub plan tier ever blocks org secrets for private repos, fall back to `gh secret set --repo St-John-Software/<repo>` per consuming repo — still no workflow change.

### One-time bootstrap

The org-level secrets do not exist until an operator creates them — Flux and migration `0042` only mint the Garage key and the in-cluster `pages-s3-credentials` Secret; nothing in this repo can reach GitHub's or Forgejo's org settings. Do this once, after `0042` has completed (`kubectl get secret pages-s3-credentials` succeeds), before the first consuming repo follows [Adding a repo](#adding-a-repo):

1. Read the values: `kubectl get secret pages-s3-credentials -o jsonpath='{.data.access-key-id}' | base64 -d` (and `secret-access-key`).
2. Set them as org-level Actions secrets on GitHub, visible to private repos:
   ```
   gh secret set PAGES_S3_ACCESS_KEY_ID --org St-John-Software --visibility all --body "<access-key-id>"
   gh secret set PAGES_S3_SECRET_ACCESS_KEY --org St-John-Software --visibility all --body "<secret-access-key>"
   ```
3. Set the same two names as org-level Actions secrets on the Forgejo `St-John-Software` org (org Settings → Actions → Secrets in the Forgejo web UI), with the same values.
4. Confirm both are visible to a private repo: `gh secret list --org St-John-Software` should list both names; on Forgejo, open a private repo's Settings → Actions → Secrets and confirm the org secrets are inherited there.

Until this is done, a workflow that follows the recipe below runs `aws s3 sync` with empty `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` and its upload fails.

### Rotation runbook

1. `kubectl delete secret pages-s3-credentials`
2. `kubectl patch configmap migration-state --type=json -p '[{"op":"remove","path":"/data/0042-pages-bucket"}]'`
3. Wait for the next migration run (Flux recreates the `migration-runner` Job within ~10 minutes). `0042` deletes every existing `pages-publisher` key — the old key stops working at once — mints a fresh one and recreates the Secret. The bucket and its content survive.
4. Read the new values: `kubectl get secret pages-s3-credentials -o jsonpath='{.data.access-key-id}' | base64 -d` (and `secret-access-key`).
5. Update `PAGES_S3_ACCESS_KEY_ID` / `PAGES_S3_SECRET_ACCESS_KEY` at org level on both GitHub and Forgejo.
6. `kubectl rollout restart statefulset/claws` so Claws' env picks up the new Secret values (no reloader runs in this cluster). The janitor reads the Secret fresh on each run.

## Adding a repo

1. **Tool.** Add `awscli2` to the repo's `flake.nix` devShell. CI tools come from the repo's own flake, never the runner.
2. **Publish on GitHub.** In the workflow that builds the preview, on `runs-on: [self-hosted, linux]` with the job shell set to the repo's devShell (copy `.github/actions/setup-nix` and the `nix develop … --command bash -euo pipefail {0}` shell from `St-John-Software/claws`):

   ```yaml
   - name: Publish preview
     # Fork PRs get no secrets; skip rather than fail.
     if: github.event.pull_request.head.repo.full_name == github.repository
     env:
       AWS_ACCESS_KEY_ID: ${{ secrets.PAGES_S3_ACCESS_KEY_ID }}
       AWS_SECRET_ACCESS_KEY: ${{ secrets.PAGES_S3_SECRET_ACCESS_KEY }}
       AWS_DEFAULT_REGION: garage
       AWS_ENDPOINT_URL: https://s3.home.bstjohn.net
       AWS_CONFIG_FILE: ${{ runner.temp }}/aws-config
       # Never interpolate these into the script body.
       HEAD_SHA: ${{ github.event.pull_request.head.sha }}
       PR_NUMBER: ${{ github.event.number }}
     run: |
       case "$PR_NUMBER" in ''|*[!0-9]*) echo "::error::bad PR number"; exit 1 ;; esac
       printf '[default]\ns3 =\n    addressing_style = path\n' > "$AWS_CONFIG_FILE"
       SHA8="${HEAD_SHA::8}"; PREFIX="ha-carlink/pr/pr-${PR_NUMBER}"
       aws s3 sync ./hardware/pcb/fab/preview "s3://pages/${PREFIX}/${SHA8}/" --delete
       aws s3 rm "s3://pages/${PREFIX}/" --recursive --exclude "${SHA8}/*"
       echo "https://pages.home.bstjohn.net/${PREFIX}/${SHA8}/"
   ```

   Replace `ha-carlink` and the source directory with the repo's own. The echoed URL is what goes in the PR comment. The directory must contain an `index.html`.
3. **Publish on Forgejo.** Put the same step, unmodified, in `.forgejo/workflows/` with `runs-on: [self-hosted, linux]`. The in-cluster job image already has nix; the secret names are the Forgejo org-level secrets of the same name, and `github.*` contexts resolve the same way under Forgejo Actions.
4. **Cleanup on close.** Add `pages-cleanup.yml` triggered on `pull_request: types: [closed]`, gated on `github.event.pull_request.head.repo.full_name == github.repository`, with the same env (minus `HEAD_SHA`) and:

   ```bash
   # An empty or non-numeric value would widen the target to every pr-* prefix.
   case "$PR_NUMBER" in ''|*[!0-9]*) echo "::error::Refusing to delete: '$PR_NUMBER'"; exit 1 ;; esac
   printf '[default]\ns3 =\n    addressing_style = path\n' > "$AWS_CONFIG_FILE"
   aws s3 rm "s3://pages/ha-carlink/pr/pr-${PR_NUMBER}/" --recursive
   ```

   Keep it a separate workflow from the build, so a close event does not re-render and re-upload the preview it is deleting (the same reasoning as 3d-models' `pr-preview-cleanup.yml`).
5. **Rendered docs.** Publish the `docs` kind from a `push` to `main` with `<ref>` = `main` and `HEAD_SHA: ${{ github.sha }}`; the supersession `rm` keeps only the latest build.
6. **Secrets.** Nothing per repo, once the [one-time bootstrap](#one-time-bootstrap) has been done: the org-level secrets already cover it (see [The credential](#the-credential)).

## Operations

- Health: Gatus `Pages (Garage)` probes `http://garage:3903/health`; Homepage has a `Pages` tile.
- Bucket state: `GetBucketInfo` on the admin API shows the quota and usage; the admin token is `garage-secrets`/`GARAGE_ADMIN_TOKEN`.
- Fresh cluster: the Garage pod sits in `CreateContainerConfigError` until migration `0041` creates `garage-secrets`, and `0042` waits up to 120s for a Ready Garage pod, then retries on the next run if it isn't. Both self-resolve.
