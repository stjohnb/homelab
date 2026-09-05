# Config PVC Backups

**Deep dive.** Read this when restoring a servarr/Jellyfin/Plex config PVC or changing the two backup CronJobs. For NAS-dependent storage generally, see [nas-k3s.md](nas-k3s.md).

Eight config PVCs are node-local `local-path` volumes. Until the `config-backup` CronJob existed they had no backup of any kind — a fact established the hard way in July 2026, when the storage VM was destroyed during the TrueNAS → NixOS migration and the configs survived only because the underlying zvol happened to be left intact (see [July 2026 incident](#july-2026-incident-record-only) below).

## Two CronJobs, split by node

A `local-path` PVC is bound to one node by immutable `nodeAffinity`, and one pod cannot mount volumes bound to two different nodes. Since [#800](https://github.com/St-John-Software/fleet-infra/issues/800) these eight PVCs live on two nodes, so the backup is two CronJobs:

| CronJob | Node | Apps | Schedule | Deadline |
|---------|------|------|----------|----------|
| `config-backup` (`cronjob.yaml`) | `k3s-nas` (`nodeSelector` + toleration) | sonarr, radarr, bazarr, transmission | 02:00 | 1800s |
| `config-backup-players` (`cronjob-players.yaml`) | unpinned → `k3s` | plex, jellyfin, jellyseerr, seerr | 01:00 | 3600s |

Both write to the same NFS destination and both mount the **hard** `media-pvc`, never `media-soft-pvc` — a backup must not ride a mount that can return `EIO` mid-write. That means `config-backup-players` still needs the NAS awake even though the apps it backs up no longer do; it simply waits in `ContainerCreating` otherwise, exactly as the servarr job does.

The backup script itself lives in a ConfigMap (`apps/config-backup/script-configmap.yaml`, mounted at `/scripts/backup.sh`) rather than inline in a CronJob's `args`, so both CronJobs share it verbatim. The list of apps is not baked into the script — each CronJob passes its own as the `APPS` environment variable, a space-separated list of `app:owner-uid:owner-gid` triples.

## What is backed up

| App | PVC | CronJob | Mount in the backup pod | Approx. `/config` size |
|-----|-----|---------|-------------------------|------------------------|
| Sonarr | `sonarr-local-config-pvc` | `config-backup` | `/config/sonarr` | 56M (34M `logs/`, 15M `MediaCover/`, `sonarr.db` 5.3M) |
| Radarr | `radarr-local-config-pvc` | `config-backup` | `/config/radarr` | 20M (12M `logs/`) |
| Bazarr | `bazarr-local-config-pvc` | `config-backup` | `/config/bazarr` | 488K |
| Transmission | `transmission-local-config-pvc` | `config-backup` | `/config/transmission` | 28K |
| Jellyfin | `jellyfin-config` | `config-backup-players` | `/config/jellyfin` | 1.2M |
| Jellyseerr | `jellyseerr-config` | `config-backup-players` | `/config/jellyseerr` | 4.4M |
| Seerr | `seerr-config` | `config-backup-players` | `/config/seerr` | single-digit MB |
| Plex | `plex-config` | `config-backup-players` | `/config/plex` | ~11G on disk, single-digit MB archived (see below) |

Excluded from every archive: `logs/`, `log/`, `cache/`, `Cache/`, `MediaCover/`, `transcodes/`, `Sentry/`, `*.db-wal`, `*.db-shm`, `*.sqlite3-wal`, `*.sqlite3-shm`, `*.pid`, and `bandwidth-groups.json.tmp.*` (Transmission accumulates hundreds of zero-byte temp files dating back to April 2026). The hot-copy loop matches `*.db` **and** `*.sqlite3`, because Seerr names its database `db.sqlite3` — without the second glob its archive would contain only the torn `tar` copy, which looks like a backup and is not one.

### Plex-specific exclusions

Plex's `/config` is ~11G, nearly all of it regenerable. The script builds a per-app exclude file (busybox `tar -X`) and, for `plex` only, drops these directories under `Library/Application Support/Plex Media Server/`:

`Cache`, `Metadata`, `Media`, `Logs`, `Crash Reports`, `Diagnostics`, `Updates`, `Codecs`, `Scanners`

What is deliberately **not** excluded:

- **`Plug-in Support/`** — holds `Databases/` (the library database, watch history, play state) and `Preferences/`. This is the part that actually matters.
- **`Preferences.xml`** — the server's `MachineIdentifier` and claim token. Lose it and the server becomes a *new* server to plex.tv and to every paired client (see the `PLEX_CLAIM` comment in `apps/plex/deployment.yaml`).

**A restore rebuilds artwork on first scan.** `Metadata/` and `Media/` are the downloaded posters, fanart, chapter thumbnails and analysis data. After restoring an archive, Plex re-fetches them in the background over the following hours — the library, watch history and server identity are intact immediately, but posters appear blank until the refresh catches up. That is the intended trade: a few MB nightly instead of 11G.

Because the databases live at `Library/Application Support/Plex Media Server/Plug-in Support/Databases/*.db` — six levels below `/config/plex` — the SQLite hot-copy loop searches to `-maxdepth 6`. At the original `-maxdepth 3` the Plex databases would be missed entirely and the archive would contain only the torn WAL copy from `tar`.

That loop also had to stop being `for db in $(find …)`. Plex's paths contain spaces (`Application Support`, `Plex Media Server`, `Plug-in Support`), which word-splitting shreds into nonexistent paths — every `.backup` would fail, `FAILED=1`, and the Plex archive would be dropped. It now reads a `find` result file with `while IFS= read -r`; the temp file rather than a pipeline is deliberate, because a `find | while` pipeline puts the loop in a subshell and the `ok=0` assignment is lost.

**`Backups/` and `backup/` are deliberately kept.** Those are Sonarr's, Radarr's and Bazarr's own scheduled restore points — 1.6M and 224K respectively — and are the fastest path back to a working app. Excluding them would throw away the most useful thing in the directory.

With logs and artwork stripped, every archive lands in the single-digit MB range. That matters: `/mnt/SSD-POOL/media` is at 95% capacity (92G free). If any archive ever exceeds ~500MB, tighten the exclusions rather than lowering `RETAIN`.

## Where and when

| Setting | `config-backup` | `config-backup-players` |
|---------|-----------------|-------------------------|
| Schedule | `0 2 * * *` (daily 02:00, Europe/London) | `0 1 * * *` (daily 01:00, Europe/London) |
| Node | `k3s-nas` (`nodeSelector: node-role.kubernetes.io/storage: "true"`) | `k3s` (unpinned; that is where its PVCs are) |
| Destination | `/mnt/SSD-POOL/media/backups/config/<app>/<app>-config-<YYYYmmdd-HHMMSS>.tar.gz` | same |
| Retention | 14 archives per app | same |
| Job deadline | 30 minutes (`activeDeadlineSeconds: 1800`) — covers the NFS mount wait when the NAS is coming back online | 60 minutes (`activeDeadlineSeconds: 3600`) — same wait, plus the extra walk over Plex's ~11G config tree |
| Retries | `backoffLimit: 1` | same |

### Why these times

The NAS (`k3s-nas`) powers itself off at **03:03 Europe/London every night**, unconditionally (`systemd.timers.nightly-shutdown`, `nixos-config` `hosts/nas/default.nix`), and there is no scheduled wake — it comes back only when woken by hand via the Home Assistant webhook behind `wake.home.bstjohn.net`. Any job that depends on the NAS and is scheduled after ~03:03 can never succeed. This is not theoretical: `config-backup` at its old 03:30 schedule recorded **zero successful runs** between its creation on 2026-08-07 and 2026-08-13, while `forgejo-backup-offsite` at 03:00 succeeded on consecutive nights over the same window — that pins the cutoff precisely between 03:00 and 03:30.

Both jobs' deadlines must also fit before 03:03: 01:00 + the 3600s players deadline finishes by 02:00, and 02:00 + the 1800s servarr deadline finishes by 02:30, both comfortably clear. Anything added to this schedule window in future must be placed the same way. `containerd-gc-storage` at 04:30 is still on the wrong side of the cutoff — a known follow-up, out of scope here since it's a cache GC rather than a backup.

Each Job mounts several RWO `local-path` volumes at once. That works because every volume it mounts is bound to the node the Job runs on — RWO permits multiple pods on the *same* node. It is also exactly why the split exists.

The script guards on `/proc/mounts` before writing anything: if `/media` is not actually an NFS mount, the Job fails immediately rather than writing a "backup" into the pod's own ephemeral filesystem.

## Why SQLite `.backup` and not just `tar`

The apps keep live WAL-mode SQLite databases (`/config/{sonarr,radarr}.db` + `logs.db`, `/config/db/bazarr.db`, `/config/data/{jellyfin,library}.db`, Plex's `Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db`; Transmission has none). A plain `tar` of a live WAL database can capture a torn page set — the copy looks fine until you try to restore it. The online backup API (`sqlite3 … ".backup"`) cannot produce a torn copy, so the script tars everything *except* the databases, then overwrites each `.db` in the staging directory with a `.backup` copy. A 10-second busy timeout (`-cmd ".timeout 10000"`) lets it wait out a writer rather than failing on a lock.

Two consequences worth knowing:

- **The config mounts are read-write, not `readOnly: true`.** SQLite's online backup needs to create a `-shm` file next to the database. A read-only mount makes every `.backup` fail.
- **The script `chown`s `-wal`/`-shm` files back afterwards.** `sqlite3` runs as root in the backup pod and may recreate those sidecar files owned by root; the servarr apps run as `1000:1000` (`linuxserver/*` with `PUID`/`PGID`), Jellyfin as root and Plex as `972:972` (`PLEX_UID`/`PLEX_GID`, inherited from the old FreeBSD jail), so the script hands ownership back per app, which is why the pod holds `CAP_CHOWN` — see below. Without this the app can fail to write after its next restart.

A failure on any single app sets `FAILED=1` and the Job exits non-zero, so a partial failure still surfaces as a failed Job. A *missing or empty* PVC, however, only logs `WARN … skipping` — a green Job is not proof every app in its `APPS` list was captured. Check the log after the first run following any change here.

## Why the backup pod adds four capabilities

Both CronJobs run their container as `runAsUser: 0` with `capabilities: {drop: [ALL], add: [DAC_READ_SEARCH, DAC_OVERRIDE, CHOWN, FOWNER]}`. Dropping `ALL` removes root's usual DAC-bypass, so uid 0 can no longer read files it doesn't own by mode alone. Plex keeps several `0600` files owned by uid 972 (`Preferences.xml`, `.LocalAdminToken`) — without these capabilities back, `tar` fails with `Permission denied` on every one of them, which is exactly what happened to `config-backup-players` during the #800 cutover on 2026-08-13. `allowPrivilegeEscalation: false` (`no_new_privs`) is retained on both Jobs and does not conflict — it blocks a process from *gaining* new privileges via `exec`, not from using capabilities already in its initial permitted set.

Each capability maps to a specific step in `backup.sh`:

- `DAC_READ_SEARCH` / `DAC_OVERRIDE` — the initial `tar -cf` read of the source tree (script-configmap.yaml:53) and the `sqlite3 ".backup"` online copy (script-configmap.yaml:75), both of which must read files owned by the app's uid.
- `CHOWN` — handing `-wal`/`-shm` sidecar files back to the app's uid/gid (script-configmap.yaml:84). Root without `CAP_CHOWN` cannot `chown` a file it doesn't already own, even to the same uid.
- `FOWNER` — re-extracting the staged tar (script-configmap.yaml:59) restores each file's original ownership before its mode bits are reapplied; once a staged file is owned by uid 972, root without `CAP_FOWNER` can't `chmod`/`utime` it.

## Alerting

Five Grafana rules in the `CronJob Monitoring` group (`apps/monitoring/kube-prometheus-stack.yaml`):

| Rule | Condition | Severity |
|------|-----------|----------|
| Config Backup Job Failed | `kube_job_status_failed > 0` for `config-backup-[0-9]+` AND `k3s-nas` continuously Ready for 26h | warning |
| Config Backup (Players) Job Failed | `kube_job_status_failed > 0` for `config-backup-players.*` with `reason!="DeadlineExceeded"` | warning |
| Config Backup Schedule Missed | No new job in >2 days (2x the daily interval); before the first run, measured from the CronJob's creation timestamp | warning |
| Config Backup Job Stale | Last success (or CronJob creation, if never successful) more than 14 days ago | warning |
| Config Backup (Players) Job Stale | Last success (or CronJob creation, if never successful) more than 14 days ago | warning |

The players rule uses no node guard and no `min_over_time` window; instead it excludes `reason="DeadlineExceeded"`, which is precisely the NAS-asleep signature — the pod sits in `ContainerCreating` waiting on the hard-mounted `media-pvc` until it is killed by `activeDeadlineSeconds`. A container that actually ran and failed instead yields `reason="BackoffLimitExceeded"` (or similar) and alerts within 5 minutes. The 26-hour Ready gate used by the servarr rule was rejected here: the NAS powers off nightly at 03:03 and can essentially never be continuously Ready for 26 hours, so that gate would suppress this rule almost permanently — the same trap as #698, where a 7-hour Immich guard hid three months of empty-database backups.

The two `*-job-stale` rules are the backstop for a genuine failure that itself looks like a timeout (e.g. a legitimate `DeadlineExceeded` from a run that ran long, or a night the NAS just never got woken). They fire after 14 days rather than the tighter 48h window a fully awake system could use, because the NAS has no wake schedule and consecutive missed nights are normal — a shorter window would false-fire on nothing more than a stretch of unused evenings. `config-backup-job-stale` exists because `config-backup-job-failed`'s 26-hour guard can never be satisfied by a box that powers off nightly, so the guarded rule alone cannot prove that backup is alive — which is exactly how six days of zero successful servarr backups went unnoticed before this rule existed.

The schedule-missed rule matches `cronjob="config-backup"` exactly and so does not cover the players CronJob.

The 26-hour Ready guard is the same one `containerd-gc-storage` uses, for the same reason: `k3s-nas` is deliberately powered off much of the time, so the pod fails to mount NFS, hits its deadline and records `Failed` — an expected outcome, not an incident. The guard plus `noDataState: OK` suppresses those. `kube_cronjob_status_last_schedule_time` keeps advancing while the node is off, so the schedule-missed rule does not false-fire either. The schedule-missed rule runs `noDataState: OK` and anchors to `kube_cronjob_created` when no schedule has been recorded, because kube-state-metrics emits no `kube_cronjob_status_last_schedule_time` series before a CronJob's first run. Without that, it fired a spurious `DatasourceNoData` between PR #770 creating the CronJob and its first 03:30 run (issue #772), and again when the `k3s` node's runtime restarted on 2026-08-10 (issue #783). The *job-failed* rule's 26-hour guard also mis-fired on 2026-08-11 (#793): a kube-state-metrics pod-IP change orphaned the guard's Prometheus series, leaving it frozen at its last value long enough to satisfy the guard even though `k3s-nas` had gone NotReady. The guard now aggregates with `max by (node)` inside a `[26h:1m]` subquery so a dead series can no longer prop it up — see [docs/monitoring.md](monitoring.md).

Note the servarr `config-backup-job-failed` rule's 26-hour guard only rules out the NAS-offline cause. The job also runs `apk add --no-cache sqlite=<pinned version>` against the Alpine mirror on every execution, so a `Failed` alert while `k3s-nas` has been continuously Ready for 26h can mean either a real backup problem or a transient mirror/internet outage — check the job logs for an `apk` error before assuming the former.

All five route to the `Slack - CronJobs` contact point via the existing `alertname =~ ".*Job.*|.*Schedule.*|.*Running Too Long"` match — every title above contains "Job".

## Restore runbook

Restoring is a scale-down, extract, fix ownership, scale-up cycle. Example for Sonarr:

```bash
# 1. Stop the app so it is not writing to its own database mid-restore.
kubectl scale deploy/sonarr --replicas=0
kubectl wait --for=delete pod -l app=sonarr --timeout=120s

# 2. Start a throwaway pod on the storage node with the config PVC and the archive share.
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: config-restore
spec:
  restartPolicy: Never
  nodeSelector:
    node-role.kubernetes.io/storage: "true"
  tolerations:
    - key: node-role.kubernetes.io/storage
      operator: Equal
      value: "true"
      effect: NoSchedule
  containers:
    - name: restore
      image: alpine:3.22
      command: ["sleep", "3600"]
      volumeMounts:
        - name: config
          mountPath: /config
        - name: media
          mountPath: /media
  volumes:
    - name: config
      persistentVolumeClaim:
        claimName: sonarr-local-config-pvc
    - name: media
      persistentVolumeClaim:
        claimName: media-pvc
EOF

# 3. Extract. Pick the archive you want first:
kubectl exec config-restore -- ls -lt /media/backups/config/sonarr/
kubectl exec config-restore -- tar -xzf /media/backups/config/sonarr/sonarr-config-<STAMP>.tar.gz -C /config

# 4. Fix ownership — 1000:1000 for the linuxserver apps, root for Jellyfin.
kubectl exec config-restore -- chown -R 1000:1000 /config

# 5. Clean up and bring the app back.
kubectl delete pod config-restore
kubectl scale deploy/sonarr --replicas=1
```

Substitute the PVC name and app from the table above. For Jellyfin and Jellyseerr use `chown -R 0:0 /config`; for Plex use `chown -R 972:972 /config`; for Seerr use `chown -R 1000:1000 /config` (the image runs as `node`). Restoring into a *non-empty* config directory overlays rather than replaces — wipe the directory first if you want the archive's state exactly.

**For Plex, Jellyfin, Jellyseerr and Seerr, drop the `nodeSelector`/`tolerations` from that pod.** Their config PVCs are bound to `k3s`, not `k3s-nas` — the storage-node pinning above would leave the pod `Pending` forever. Keep `media-pvc` as the archive source either way; the NAS has to be awake for a restore. A ready-made version is in [nas-app-tier-migration.md](nas-app-tier-migration.md#restore-job).

## Not covered

- **`postgres-data`** — deliberately excluded. The shared PostgreSQL instance is covered by logical `pg_dump`s: `apps/postgres/cronjob-db-backup.yaml` nightly for every database except `immich`, and `apps/immich/cronjob-db-backup.yaml` 6-hourly for `immich`. A hot `tar` of a live data directory is not a backup; see [postgres.md](postgres.md#backups).
- **`immich-ml-cache-pvc`** — regenerable model cache, not worth the space.
- **`prowlarr-local-config-pvc`, `overseerr-local-config-pvc`** — still unbacked. They live on `k3s`, which is now where `config-backup-players` runs, so the original blocker (one pod cannot mount volumes bound to two nodes) is gone: adding them is a matter of appending to that CronJob's `APPS` list and mounting their PVCs. Worth a follow-up issue.

## July 2026 incident (record only)

Not a procedure — this already happened and the recovery is complete. Recorded because the details cost real time and would otherwise be rediscovered the hard way.

The `k3s-nas` bhyve VM died when the TrueNAS box was migrated to NixOS. Its disk survived as the ZFS volume `SSD-POOL/k3s-o8383j`, and **seven** PVCs were recovered from it — two more than the five this CronJob now covers:

| PVC | Recovered size |
|-----|----------------|
| `immich-ml-cache-pvc` | 583M |
| `immich-postgres-pvc` | 301M (live PG16 data directory) |
| `sonarr-local-config-pvc` | 56M |
| `radarr-local-config-pvc` | 18M |
| `jellyfin-config` | 720K |
| `transmission-local-config-pvc` | 676K |
| `bazarr-local-config-pvc` | 496K |

Two things that were not obvious:

- **The zvol was LVM, not plain ext4.** Partition 3 is an `LVM2_member` holding `ubuntu-vg/ubuntu-lv`, so `mount /dev/zd0p3` fails with `unknown filesystem type 'LVM2_member'`. The kernel had already exposed `zd0p1..p3` and the LV was already active, so `kpartx` turned out to be unnecessary.
- **k3s's local-path root is `/var/lib/rancher/k3s/storage/pvc-<uid>_default_<pvc-name>/`**, not `/opt/local-path-provisioner`.

Commands as run:

```bash
zfs snapshot SSD-POOL/k3s-o8383j@pre-recovery-20260728   # safety net, taken first
mount -o ro /dev/ubuntu-vg/ubuntu-lv /mnt/recovery
rsync -aHAX --numeric-ids /mnt/recovery/var/lib/rancher/k3s/storage/ "$DEST/"
```

Mounted read-only throughout. `--numeric-ids` matters — the servarr configs and the Immich PG data directory each have specific numeric owners the services expect. Verified at 2313 files on both sides with `rsync --checksum --dry-run` reporting zero differences.

Copies retained at `/mnt/SSD-POOL/media/backups/k3s-pvcs-20260728/` (mode 700) and `~/Backups/k3s-pvcs-20260728/k3s-pvcs.tar.gz` on the workstation. The zvol and its snapshot (46.8G combined) still exist; **do not destroy them from this repo's side** — reclaiming them is tracked in `St-John-Software/nixos-config#26`.

## Limitation: no off-box copy

The nightly archives land on SSD-POOL, the same pool the source volumes live on. That covers the failure that actually happened — VM disk destroyed, ZFS pool intact — but it does not cover pool loss. There is still no automated off-box copy of any of this; the workstation tarball above is manual and one-off. Recurring off-box replication is tracked in `St-John-Software/nixos-config#20`.

## Related

- [docs/nas-k3s.md](nas-k3s.md) — the storage worker node and its offline behaviour
- [docs/servarr.md](servarr.md) — the apps whose configs these are
- [docs/monitoring.md](monitoring.md) — CronJob alert rules and the 26-hour Ready guard
- [docs/immich.md](immich.md) — Immich's own database backup
