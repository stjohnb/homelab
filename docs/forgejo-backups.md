# Forgejo Backups

Operator runbook for the Forgejo backup CronJobs and the restore procedure.

Forgejo (`git.home.bstjohn.net`, `apps/forgejo/`) stores everything — the embedded SQLite database, repositories, LFS objects, JWT and SSH host keys, and `app.ini` — on a single 10 Gi `local-path` PVC (`forgejo-data`) on node `k3s`. As it becomes the canonical forge for repos migrated off GitHub, that PVC needs a backup story.

## Two-stage design

| Stage | CronJob | Schedule | Destination | Retention |
|-------|---------|----------|-------------|-----------|
| 1 | `forgejo-backup` | daily 02:30 Europe/London | `forgejo-backups` PVC (`local-path`, node `k3s`) | 14 dumps |
| 2 | `forgejo-backup-offsite` | daily 03:00 Europe/London | `192.168.0.128:/mnt/SSD-POOL/media/backups/forgejo/` | 14 dumps |

**Stage 1** runs `forgejo dump --type tar.gz` in a second pod using the same image tag (a hard requirement, not a convention) and the same `forgejo-data` PVC as the running server, and writes the archive to a dedicated `local-path` PVC. It mounts no NFS, so nothing external can block it. It must succeed every night.

The Stage 1 image tag must stay identical to `apps/forgejo/deployment.yaml`. `forgejo dump` reads the database with the schema its own binary expects, so a stale backup image fails outright once the server has migrated — from 2026-07-30 to 2026-08-01 the CronJob was left on 14.0.3 against a 15.0.5-migrated DB and failed with `no such column: remote_address`, so three consecutive nightly runs produced no archive at all. `task validate` and CI enforce the match via `scripts/check-image-tag-consistency.sh`.

`forgejo dump` rewrites the `--file` argument so it ends in the `--type` suffix, and exits 0 regardless. From 2026-07-29 to 2026-08-04 the job passed `--file .../.forgejo-dump-<ts>.tar.gz.partial`, so forgejo appended `.tar.gz` and wrote `.forgejo-dump-<ts>.tar.gz.partial.tar.gz`; the verification `tar` then read a path that did not exist and the job failed with `FATAL: archive contains no forgejo-db.sql`. **No valid archive was produced on any night in that window.** The job now dumps into an empty `/backups/.staging` directory and takes whatever file appears, rather than assuming the output path. Retagging the image (#745) fixed a separate, concurrent fault and did not resolve this one.

**Stage 2** copies any dumps not already present on the NAS. The NAS is deliberately powered off most of the time (see [docs/nas-k3s.md](nas-k3s.md)), so Stage 2 failing is often expected — but it has **two failure modes that mean opposite things**. Read the Job condition (`kubectl get job <name> -n default -o jsonpath='{.status.conditions}'`) before concluding anything:

- **`reason: DeadlineExceeded`, no pod retained.** The `soft/retry=0` NFS mount failed, the pod sat in `ContainerCreating` until `activeDeadlineSeconds: 900` expired, and there are no logs because there is no pod. **The NAS is off: expected and harmless.** Observed on `forgejo-backup-offsite-29763480`, 2026-08-04.
- **Pod started and exited 1 with `FATAL: /backups holds no forgejo-dump-*.tar.gz`.** The NAS was reachable but Stage 1 has produced no archive. This is **a Stage 1 failure surfacing 30 minutes late** and is not harmless. Observed 2026-07-30 (issue #735) — it was correct, and was wrongly dismissed as the NAS being off.

**Stage 1 failing is never expected** and must be investigated the same day.

The split exists because "did we take a backup" must not be coupled to "is the NAS powered on". The NFS PersistentVolume used by Stage 2 (`forgejo-backup-nfs-pv`) points at the same export as `media-nfs-pv` but mounts `soft,timeo=50,retrans=2,retry=0` rather than `hard,intr`: this volume is mounted from the 24/7 control-plane node, where a hung `hard` NFS mount is a far worse failure than a skipped offsite copy. With the NAS off, the mount fails fast, the pod stays in `ContainerCreating`, and `activeDeadlineSeconds: 900` fails the job.

Neither job sets a `nodeSelector`. Both mount a `local-path` PVC whose PV carries node affinity for `k3s`, so the scheduler pins them there implicitly.

## Archive layout

A `forgejo dump` tar.gz contains, at the top level:

- **`forgejo-db.sql`** — logical SQL dump of the database. **This is the authoritative copy of the database.** (Note the name: `forgejo-db.sql`, not `gitea-db.sql`.) On an empty forge it is roughly 74 KB.
- **`app.ini`** — copy of the configuration.
- **`data/`** — the whole work directory, including `data/custom/conf/app.ini`, `data/jwt/private.pem`, `data/ssh/gitea.rsa`, `data/indexers/`, and a **hot** `data/data/gitea.db` plus its `-wal` and `-shm` files.
- **`repos/`** — bare repositories. This appears only once repos exist; a forge with zero repos produces no `repos/` entry.

**Never restore from the hot `data/data/gitea.db`.** It is copied while the server is writing and its WAL may be inconsistent. Always restore the database from `forgejo-db.sql`.

Stage 1 verifies content rather than trusting the exit status: it rejects an archive with no `forgejo-db.sql`, one where `forgejo-db.sql` is under 20 KB, or one missing `data/custom/conf/app.ini`. A rejected archive is deleted and the job fails. There is deliberately no assertion on `repos/` — a forge with zero repos produces no `repos/` entry, so such a check would fail on an empty forge.

## What is not covered

- Stage 1's copy sits on the same physical disk as `forgejo-data`. It protects against a bad upgrade, an admin mistake, database corruption or an accidental repo deletion — **not** against loss of node `k3s`.
- Stage 2 is the off-node copy. There is still no off-*box* copy (tracked in `nixos-config#20`).
- The GitHub push mirror (#703) is an independent second copy of repo content only — no issues, no users, no settings.

## Restore procedure

1. **Scale down the server** so nothing writes to the PVC while it is being replaced:

   ```bash
   kubectl scale deploy/forgejo --replicas=0 -n default
   kubectl wait --for=delete pod -l app=forgejo -n default --timeout=120s
   ```

2. **Start a helper pod** on node `k3s` with all three volumes mounted. Save as `restore-pod.yaml` and `kubectl apply -f restore-pod.yaml` (this is a deliberate exception to the GitOps rule — it is a debugging/recovery pod, not cluster state):

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: forgejo-restore
     namespace: default
   spec:
     restartPolicy: Never
     containers:
       - name: shell
         image: alpine:3.22
         command: ["sleep", "7200"]
         securityContext:
           runAsUser: 0
         volumeMounts:
           - name: forgejo-data
             mountPath: /var/lib/gitea
           - name: backups
             mountPath: /backups
           - name: offsite
             mountPath: /media
     volumes:
       - name: forgejo-data
         persistentVolumeClaim:
           claimName: forgejo-data
       - name: backups
         persistentVolumeClaim:
           claimName: forgejo-backups
       - name: offsite
         persistentVolumeClaim:
           claimName: forgejo-backup-pvc
   ```

   If the NAS is powered off, drop the `offsite` volume and its mount — the pod will not start otherwise.

   ```bash
   kubectl exec -it forgejo-restore -n default -- sh
   ```

3. **Extract the chosen dump.** Local copies are in `/backups`; offsite copies are in `/media/backups/forgejo/`.

   ```sh
   apk add --no-cache sqlite tar
   ls -lht /backups/forgejo-dump-*.tar.gz
   mkdir /restore && tar -xzf /backups/forgejo-dump-<TS>.tar.gz -C /restore
   ```

4. **Snapshot the current state before destroying it.** `/var/lib/gitea` is the mount root and cannot be renamed, so take a tarball first and then empty it in place:

   ```sh
   tar -czf /backups/pre-restore-$(date +%Y%m%d-%H%M%S).tar.gz -C /var/lib/gitea .
   rm -rf /var/lib/gitea/*
   ```

5. **Restore the work directory** — this brings back `custom/conf/app.ini`, `jwt/`, `ssh/`, `data/` and `indexers/`:

   ```sh
   cp -a /restore/data/. /var/lib/gitea/
   ```

6. **Replace the hot database with the logical dump:**

   ```sh
   rm -f /var/lib/gitea/data/gitea.db /var/lib/gitea/data/gitea.db-wal /var/lib/gitea/data/gitea.db-shm
   sqlite3 /var/lib/gitea/data/gitea.db < /restore/forgejo-db.sql
   ```

7. **Restore repositories** (no-op on a dump taken before any repos existed):

   ```sh
   [ -d /restore/repos ] && cp -a /restore/repos/. /var/lib/gitea/git/repositories/
   ```

8. **Fix ownership, tear down the helper, scale back up:**

   ```sh
   chown -R 1000:1000 /var/lib/gitea
   exit
   ```

   ```bash
   kubectl delete pod forgejo-restore -n default
   kubectl scale deploy/forgejo --replicas=1 -n default
   ```

9. **Verify:**
   - Pod reaches Ready (`/api/healthz` probes pass).
   - Log in at https://git.home.bstjohn.net/ with a known account.
   - `git clone ssh://git@git.home.bstjohn.net:30022/<owner>/<repo>.git` succeeds for one repo.
   - Issue counts on a migrated repo match what they were before the restore.

## Rehearsing the restore

Rehearse against a scratch namespace rather than the live forge:

```bash
kubectl create namespace forgejo-restore-test
```

Create a fresh `local-path` PVC in that namespace and a Deployment copied from `apps/forgejo/deployment.yaml` (replicas 1, no ingress, `ROOT_URL` left as-is), then run steps 2–9 above against it, port-forwarding to check the result.

**Run this by hand and delete the namespace afterwards. Do not add it to `apps/`** — a permanent scratch namespace holding a copy of the JWT signing key and the SSH host keys is a liability.

## Alerting

Three Grafana rules in the `CronJob Monitoring` group (`apps/monitoring/kube-prometheus-stack.yaml`):

| Rule | Fires when | Severity | Means |
|------|-----------|----------|-------|
| `forgejo-backup-job-failed` | any failed `forgejo-backup-<n>` job | critical | The backup itself is broken — act tonight. |
| `forgejo-backup-job-stale` | `forgejo-backup` has not succeeded in 2 days | critical | There is no recent dump at all — including when no job ran. |
| `forgejo-offsite-backup-job-stale` | `forgejo-backup-offsite` has not succeeded in 14 days | warning | Backups are fine, but there is no off-node copy — power on the NAS. |

The staleness clock for `forgejo-offsite-backup-job-stale` runs from the CronJob's last *successful* run, falling back to the CronJob's creation timestamp (`kube_cronjob_created`) when it has never succeeded — kube-state-metrics emits no `kube_cronjob_status_last_successful_time` series until the first success. Without that fallback the rule sits in `DatasourceNoData` forever instead of alerting (#708). Consequence: a newly created or recreated CronJob gets a fresh 14-day grace period, and if the NAS stays off for 14 days after creation the warning fires as intended. `noDataState` is `OK`, so deleting the CronJob outright silences this rule rather than alerting.

`forgejo-backup-job-stale` uses the same last-success-with-creation-fallback expression at a 2-day threshold, matching `cronjob="forgejo-backup"` exactly rather than by regex — a `forgejo.*` regex would let a healthy Stage 2 mask a dead Stage 1, since both CronJobs now export a last-success series. It exists because `forgejo-backup-job-failed` is edge-triggered and scoped by `topk(1, kube_job_status_start_time)` to the newest Job only: it self-resolves as soon as any later run succeeds and clears when the failed Job objects are deleted, so a permanent outage reads as a stream of unrelated nightly incidents rather than one persistent "there is no backup" signal. It also covers the case `forgejo-backup-job-failed` structurally cannot see — no Job produced at all (suspended CronJob, wedged `concurrencyPolicy: Forbid`, mis-set schedule) — where `kube_job_status_failed` never increments. Stage 1 was created 2026-07-29 and produced no archive for eight days across two distinct faults — 14.0.3-vs-15.0.5 image-tag skew (`no such column: remote_address`), fixed 2026-08-03 by PR #745; then `forgejo dump` rewriting its `--file` path so verification read a file that never existed, fixed 2026-08-05 by PR #752 — and no alert ever said "you have no backup"; issues #723, #724, #734, #735, #737, #739, #746, #750 and #756 were each filed and closed as a duplicate of the last. The first unattended run under both fixes succeeded 2026-08-06 01:30 UTC. A manual `kubectl create job --from=cronjob/forgejo-backup ...` run does update the CronJob's `status.lastSuccessfulTime`, and that value survives deleting the Job, so a successful manual run clears this alert. Because `noDataState` is `OK`, deleting or renaming the `forgejo-backup` CronJob silences this rule rather than alerting — the same trade-off already accepted for the offsite rule.

`forgejo-backup-job-failed` deliberately carries **no** `k3s-nas` readiness guard, unlike the Immich backup rule. Stage 1 has no NFS dependency, so there is no expected-failure mode to suppress: any failure is real. See [docs/monitoring.md](monitoring.md).

## Manual runs

```bash
# Stage 1 — needs no NAS
kubectl create job --from=cronjob/forgejo-backup forgejo-backup-manual -n default
kubectl logs job/forgejo-backup-manual -n default
kubectl delete job forgejo-backup-manual -n default

# Stage 2 — needs the NAS powered on
kubectl create job --from=cronjob/forgejo-backup-offsite forgejo-backup-offsite-manual -n default
kubectl logs job/forgejo-backup-offsite-manual -n default
kubectl delete job forgejo-backup-offsite-manual -n default
```

### Verifying a backup actually exists

A green `forgejo-backup` Job is not proof. Check for real files:

```bash
kubectl get jobs -n default | grep '^forgejo-backup'
kubectl logs -l component=backup -n default --tail=20   # expect "Backup complete: /backups/forgejo-dump-..."
```

Files beginning with a dot (`.forgejo-dump-*`) are **not** backups — they are staging leftovers. Only `forgejo-dump-<ts>.tar.gz` counts, and only Stage 2's `for` loop consumes that name.

### Clearing retained failed Jobs

`failedJobsHistoryLimit: 3` retains failed Job and pod objects; with `backoffLimit: 1` each failed Stage 1 Job leaves two `Error` pods. The Claws pod-failure watcher re-reports every retained `Failed` pod it sees, which is why issue #746 accrued 64 occurrences from three nightly runs. After fixing a fault and confirming a manual run succeeds, delete the stale Jobs — deleting a Job deletes its pods:

```bash
kubectl get jobs -n default | grep '^forgejo-backup'
kubectl delete job -n default <names from the output above>
```

This does not violate the no-`kubectl apply` rule: Flux owns the `CronJob` objects, not the `Job` objects the CronJob controller spawns from them, so deleting Jobs is neither reverted nor drift. It also removes the `kube_job_status_failed` series, which is what clears the `forgejo-backup-job-failed` Grafana alert.

Do **not** silence the noise by lowering `failedJobsHistoryLimit` or adding `ttlSecondsAfterFinished` — that deletes the pod logs that diagnose these incidents.
