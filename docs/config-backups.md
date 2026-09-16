# Config PVC Backups

**Depth:** **Deep dive**
**Read this when:** restoring a servarr/Jellyfin/Plex config PVC or changing the two backup CronJobs.
**Read instead:** [nas-k3s.md](nas-k3s.md) for NAS-dependent storage generally.

Eight config PVCs are node-local `local-path` volumes. Until the `config-backup` CronJob existed they had no backup of any kind — a fact established the hard way in July 2026, when the storage VM was destroyed during the TrueNAS → NixOS migration and the configs survived only because the underlying zvol happened to be left intact (see [July 2026 incident](#july-2026-incident-record-only) below).

## Two CronJobs, split by node

A `local-path` PVC is bound to one node by immutable `nodeAffinity`, and one pod cannot mount volumes bound to two different nodes. Since [#800](https://github.com/St-John-Software/fleet-infra/issues/800) these eight PVCs live on two nodes, so the backup is two CronJobs:

| CronJob | Node | Apps | Schedule | Deadline |
|---------|------|------|----------|----------|
| `config-backup` (`cronjob.yaml`) | `k3s-nas` (`nodeSelector` + toleration) | sonarr, radarr, bazarr, transmission | 02:00 | 1800s |
| `config-backup-players` (`cronjob-players.yaml`) | unpinned → `k3s` | plex, jellyfin, jellyseerr, seerr | 02:05 | 3000s |

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
| Schedule | `0 2 * * *` (daily 02:00, Europe/London) | `5 2 * * *` (daily 02:05, Europe/London) |
| Node | `k3s-nas` (`nodeSelector: node-role.kubernetes.io/storage: "true"`) | `k3s` (unpinned; that is where its PVCs are) |
| Destination | `/mnt/SSD-POOL/media/backups/config/<app>/<app>-config-<YYYYmmdd-HHMMSS>.tar.gz` | same |
| Retention | 14 archives per app | same |
| Job deadline | 30 minutes (`activeDeadlineSeconds: 1800`) — covers the NFS mount wait when the NAS is coming back online | 50 minutes (`activeDeadlineSeconds: 3000`) — covers the NFS mount wait |
| Retries | `backoffLimit: 1` | same |
| Job object TTL | 48h (`ttlSecondsAfterFinished: 172800`) — finished Jobs and their pods self-delete | same |

### Why these times

The NAS (`k3s-nas`) is on a duty cycle: Home Assistant wakes it with a magic packet at **02:00 Europe/London** (the PDU outlet for the D2600 shelf first, then the packet; ~2–3 minutes to Ready), and it powers itself off at **03:03**, unconditionally (`systemd.timers.nightly-shutdown`, `nixos-config` `hosts/nas/default.nix`). `nixos-config` `docs/nas-duty-cycle.md` is the source of truth for that window. The usable slot for anything that touches the NAS is therefore roughly **02:03–03:03** — a job outside it succeeds only on a night the box was woken by hand and left up. This is not theoretical in either direction: `config-backup` at its old 03:30 schedule recorded **zero successful runs** between 2026-08-07 and 2026-08-13, and on 2026-09-10 `unifi-backup` (00:30), `config-backup-players` (01:00) and `downloads-janitor` (01:30) all failed on `activeDeadlineSeconds` with no pod ever starting while `config-backup` (02:00), `postgres-db-backup` (02:30) and `forgejo-backup-offsite` (03:00) all succeeded the same night. Earlier docs here claimed the NAS had "no scheduled wake"; that was wrong and is what put those three jobs outside the window ([#1268](https://github.com/St-John-Software/fleet-infra/issues/1268)).

Every job's deadline must also fit inside that window: `config-backup` at 02:00 + 1800s finishes by 02:30, `config-backup-players` at 02:05 + 3000s finishes by 02:55, `unifi-backup` at 02:15 + 1200s finishes by 02:35, and `downloads-janitor` at 02:25 + 900s finishes by 02:40 — all comfortably inside 02:03–03:03. Anything added to this schedule window in future must be placed the same way. `containerd-gc-storage` at 04:30 is still on the far side of the poweroff — a known follow-up, out of scope here since it's a cache GC rather than a backup.

Each Job mounts several RWO `local-path` volumes at once. That works because every volume it mounts is bound to the node the Job runs on — RWO permits multiple pods on the *same* node. It is also exactly why the split exists.

The script guards on `/proc/mounts` before writing anything: if `/media` is not actually an NFS mount, the Job fails immediately rather than writing a "backup" into the pod's own ephemeral filesystem.

## Why SQLite `.backup` and not just `tar`

The apps keep live WAL-mode SQLite databases (`/config/{sonarr,radarr}.db` + `logs.db`, `/config/db/bazarr.db`, `/config/data/{jellyfin,library}.db`, Plex's `Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db`; Transmission has none). A plain `tar` of a live WAL database can capture a torn page set — the copy looks fine until you try to restore it. The online backup API (`sqlite3 … ".backup"`) cannot produce a torn copy, so the script tars everything *except* the databases, then overwrites each `.db` in the staging directory with a `.backup` copy. A 10-second busy timeout (`-cmd ".timeout 10000"`) lets it wait out a writer rather than failing on a lock.

Two consequences worth knowing:

- **The config mounts are read-write, not `readOnly: true`.** SQLite's online backup needs to create a `-shm` file next to the database. A read-only mount makes every `.backup` fail.
- **The script `chown`s `-wal`/`-shm` files back afterwards.** `sqlite3` runs as root in the backup pod and may recreate those sidecar files owned by root; the servarr apps run as `1000:1000` (`linuxserver/*` with `PUID`/`PGID`), Jellyfin as root and Plex as `972:972` (`PLEX_UID`/`PLEX_GID`, inherited from the old FreeBSD jail), so the script hands ownership back per app, which is why the pod holds `CAP_CHOWN` — see below. Without this the app can fail to write after its next restart.

A failure on any single app sets `FAILED=1` and the Job exits non-zero, so a partial failure still surfaces as a failed Job. A *missing or empty* PVC, however, only logs `WARN … skipping` — a green Job is not proof every app in its `APPS` list was captured. Check the log after the first run following any change here.

### The sqlite install is not version-pinned, on purpose

`backup.sh` installs sqlite at run time with `apk add --no-cache sqlite` and logs
the resolved version. It used to pin the exact release (`sqlite=3.49.2-r1`), and
that pin broke the backup the first time the image tag moved: Renovate PR
[#1173](https://github.com/St-John-Software/fleet-infra/pull/1173) bumped both
CronJobs from `alpine:3.22` to `alpine:3.24` on 2026-09-08, Alpine 3.24 ships
`sqlite 3.53.4-r0` (3.22 shipped `3.49.2-r1`), and the very next run of
`config-backup-players` at 01:00 exited 1 in six seconds with
`unable to select packages: ... world[sqlite=3.49.2-r1]` before touching a single
app ([#1211](https://github.com/St-John-Software/fleet-infra/issues/1211)). The
servarr job at 02:00 failed identically and never alerted, because its rule's
26-hour `k3s-nas` Ready guard can essentially never be satisfied.

The image tag already pins the Alpine branch and therefore the sqlite version;
the apk pin only added a hand edit that no automation performs. Do not
reintroduce it. If a future Alpine bump ever does need scrutiny here, read the
`sqlite3 <version>` line the script now logs at the top of every run.

Both CronJobs still need outbound access to the Alpine mirror on every
execution — that dependency is unchanged.

### Finished Jobs are TTL'd, so a fixed failure stops re-alerting

Both CronJobs set `ttlSecondsAfterFinished: 172800` on their `jobTemplate`. Without
it, `failedJobsHistoryLimit: 1` keeps a Failed Job — and its Failed pod — until the
*next* failure replaces it, which for a nightly job that has been fixed is never.
The Claws workload watcher re-files a `[k3s] Workload failing` issue for any Failed
pod it sees, so the single apk-pin failure of 2026-09-09 01:00 was filed three times
from one pod ([#1211](https://github.com/St-John-Software/fleet-infra/issues/1211),
[#1217](https://github.com/St-John-Software/fleet-infra/issues/1217),
[#1228](https://github.com/St-John-Software/fleet-infra/issues/1228)) — the last two
after the fix had already merged. Grafana's `Config Backup (Players) Job Failed` rule
has the same problem: its `topk(1, kube_job_status_start_time)` picks the newest
players Job, which stayed the failed one all day.

48h is chosen against the alerting, not against convenience: both `*-job-failed`
rules read `kube_job_status_failed`, whose series vanishes with the Job object, and
both use `for: 5m`. Anything in the minutes range would let a real failure disappear
before it alerts. Do **not** "fix" this with `failedJobsHistoryLimit: 0` — that
deletes a failed Job the moment it finishes, taking both the alert and the logs
with it.

The TTL applies to successful Jobs too, so `successfulJobsHistoryLimit: 3` is
effectively capped at ~2 days of daily runs rather than 3. That is an accepted
trade: the archives live on the NAS, and a three-day-old success log has no value.

The TTL is not retroactive: it governs only Jobs the CronJob controller creates
after the field lands, so the two Jobs that caused #1211/#1217/#1228 had to be
deleted by hand, and #1236 was filed from the same pod four minutes after the fix
merged. As of 2026-09-09 every backup/GC CronJob in this repo carries the same
48h TTL — `unifi-backup`, `downloads-janitor`, `postgres-db-backup`,
`forgejo-backup`, `forgejo-backup-offsite`, `immich-db-backup`, `containerd-gc`
and `containerd-gc-storage` — so any new CronJob of that kind should set it
too. `migration-runner` and `admission-error-reaper` are deliberate exceptions
at `ttlSecondsAfterFinished: 600`, since both run far more frequently and need
their finished Jobs cleaned up sooner; see [monitoring.md](monitoring.md).

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

Note the servarr `config-backup-job-failed` rule's 26-hour guard only rules out the NAS-offline cause. The job also runs `apk add --no-cache sqlite` against the Alpine mirror on every execution, so a `Failed` alert while `k3s-nas` has been continuously Ready for 26h can mean either a real backup problem or a transient mirror/internet outage — check the job logs for an `apk` error before assuming the former.

All five route to the `Slack - CronJobs` contact point via the existing `alertname =~ ".*Job.*|.*Schedule.*|.*Running Too Long"` match — every title above contains "Job".

## UniFi console backup

`unifi-backup` (`apps/unifi/cronjob-backup.yaml` + `apps/unifi/script-configmap.yaml`) is a third, unrelated CronJob in this same nightly window. It backs up the UniFi Network console's own configuration — networks, VLANs, WLANs, firewall zones and policies, fixed-IP reservations — which lives only on the gateway at `192.168.0.1` and has no other copy anywhere we control ([#1187](https://github.com/St-John-Software/fleet-infra/issues/1187)).

It logs into the console over HTTPS, asks the Network application for a settings-only backup (`{"cmd":"backup","days":"0"}`), downloads the resulting `.unf`, and writes it to `/mnt/SSD-POOL/media/backups/unifi/unifi-config-<YYYYmmdd-HHMMSS>.unf`. Runs at **02:15 Europe/London**, `activeDeadlineSeconds: 1200`, `backoffLimit: 1`, `startingDeadlineSeconds: 600` (a slot missed by more than 10 minutes is skipped, not run late — see below), pinned to `k3s-nas` (`nodeSelector: node-role.kubernetes.io/storage: "true"` + toleration) and mounting the **hard** `media-pvc`, for the same reason as `config-backup` and `config-backup-players` above: the NAS is only awake in the 02:00 wake / 03:03 poweroff window described above, and a backup must not ride a mount that can return `EIO` mid-write. 02:15 + the 1200s deadline finishes by 02:35, after `config-backup` (02:00) and `config-backup-players` (02:05) and clear of `postgres-db-backup` (02:30), `downloads-janitor` (02:25) and `forgejo-backup-offsite` (03:00). Retention is 14 files (`RETAIN=14`, the same convention as `config-backup`) — a console backup is single-digit MB, so 14 of them is negligible next to the 95%-full SSD-POOL constraint noted above.

### The console-side copy

The job does not clean up after itself on the console, and does not need to. Generating a settings backup writes one fixed file, `/dl/backup/<Network version>.unf` (e.g. `10.6.101.unf`), which every subsequent run overwrites — it is not a per-run unique name, so nightly runs cannot accumulate. That file is also invisible to **Settings → System → Backups**: the console's Backups page lists only its own monthly `autobackup_<ver>_<date>_<epoch>.unf` files, and `{"cmd":"list-backups"}` returns an identical 7-entry list before and after a generate. Nothing there needs periodic manual pruning.

There is no delete command to call in any case. On Network 10.6.101, `POST /proxy/network/api/s/default/cmd/backup` with `{"cmd":"delete-backup","filename":"10.6.101.unf"}` returns `HTTP 404 {"meta":{"rc":"error","msg":"api.err.NotFound"}}` — byte-identical to the reply for a deliberately bogus `cmd`, so the command is simply not recognised, not a filename-format problem (stripping `.unf`, or passing a real autobackup filename, gives the same 404). PR [#1193](https://github.com/St-John-Software/fleet-infra/pull/1193) shipped a best-effort `delete-backup` call that logged `WARN: could not delete the generated backup from the console` on every run; [#1202](https://github.com/St-John-Software/fleet-infra/issues/1202) removed it. The only residue is that a Network upgrade changes the filename, so an old `<previous version>.unf` of a few tens of KB may be left in the console's internal backup directory — not reachable through the API or the UI, and not worth chasing.

### Credential

The job authenticates as `fleet-backup`, a dedicated **local-access-only** UniFi admin with no 2FA, via the `unifi-backup-credentials` Secret in `default` (keys `username`, `password`). It is created **imperatively**, not committed as a SOPS `*.enc.yaml`, because no automation ever sees the console password — the owner generates it by hand in the UniFi UI:

```bash
# UniFi UI → Settings → Admins & Users → Add New Admin → Local Access Only.
# Name: fleet-backup. Role: Full Management (see permissions gotcha below). No 2FA.
# Password MUST be alphanumeric only — the script refuses " and \.
kubectl create secret generic unifi-backup-credentials -n default \
  --from-literal=username=fleet-backup \
  --from-literal=password='<generated>'
```

It must be recreated by hand after a cluster rebuild. The script refuses to run if `$UNIFI_PASS` contains a `"` or `\`, since it interpolates the credential into a JSON login body via `printf` and either character would produce a malformed request. Any download under `MIN_BYTES=20000` (20 KB — a genuine settings-only `.unf` is typically 50–200 KB) is treated as an error page or a truncated transfer and discarded rather than kept.

**Permissions gotcha:** generating a backup is a privileged Network command. If the job logs an HTTP 401/403 or a body containing `api.err.NoPermission` on the `cmd/backup` POST, the local admin needs **Full Management** on the Network application rather than View Only — raise the role, do not work around it in the script.

### Transient console errors and late catch-up runs

The console returns a transient **HTTP 503** when it is busy, and the script's
curl calls carry `--retry 3 --retry-delay 5 --retry-max-time 60` so one of them
no longer kills the run. Only curl's own transient set is retried (timeouts and
HTTP 408, 429, 500, 502, 503, 504) — a 401/403 from the `cmd/backup` POST still
fails immediately, because that means the `fleet-backup` admin needs Full
Management (the permissions gotcha above) and retrying would only hide it. Each
of the three calls now logs `step N/3: …` first, so a failure names the call.

The CronJob also sets `startingDeadlineSeconds: 600`. Without it the CronJob
controller fires the most recent missed schedule as soon as the object is
edited: when the 02:15 schedule from [#1268](https://github.com/St-John-Software/fleet-infra/issues/1268)
was applied at 11:31 UTC on 2026-09-10 it immediately created
`unifi-backup-29816715` for the already-passed 01:15 UTC slot, in the middle of
the day, in the same second as a manual verification Job. The console 503'd one
of the two logins and that pod failed
([#1280](https://github.com/St-John-Software/fleet-infra/issues/1280)); the
Job's own `backoffLimit: 1` retry pod succeeded eleven seconds later. Any
NAS-dependent run outside 02:03–03:03 is worthless anyway, so skipping the slot
is the right outcome. The trade-off: if the CronJob controller is unavailable
across the whole 02:15 slot by more than 10 minutes, that night is skipped
silently — there is no schedule-missed rule for this CronJob (the existing one
matches `cronjob="config-backup"` exactly), so only `unifi-backup-job-stale`
(14 days) would eventually notice.

A one-off run is still `kubectl create job --from=cronjob/unifi-backup
unifi-backup-manual -n default` — but note `concurrencyPolicy: Forbid` does not
cover it. `create job --from=` does set an ownerReference back to the CronJob,
so the Job counts against `successfulJobsHistoryLimit`, but it is never added to
the CronJob's `.status.active`, which is the only list `Forbid` consults; the
controller logs `UnexpectedJob  Saw a job that the controller did not create or
forgot`. Do not start one within a minute of the 02:15 slot, and `kubectl delete
job unifi-backup-manual -n default` when you are done — history limits and the
inherited 48h TTL only reap it days later, and until then a Failed pod of its
own keeps the Claws workload watcher re-filing issues (this one was re-filed
sixteen times in under four hours).

### Restore

1. UniFi UI → **Settings → System → Backups → Restore** → upload the `.unf`. The console reboots and comes back with the restored networks, VLANs, WLANs, firewall policies and fixed-IP reservations.
2. A `.unf` can only be restored onto the same UniFi Network major version or newer, so keep the archive alongside a note of the running version at backup time.
3. To fetch a file off the NAS: `kubectl exec` into any pod with `media-pvc` mounted (e.g. the `config-restore` pod recipe above, keeping only the `media` volume) and `kubectl cp` the `.unf` out.

The console's own cloud backup (Ubiquiti account) is not a substitute for this job — it lives with the vendor and cannot be diffed or restored from our side.

### Alerting

Two more Grafana rules in the `CronJob Monitoring` group (`apps/monitoring/kube-prometheus-stack.yaml`), following the same pattern as `config-backup-players-job-failed` / `config-backup-players-job-stale` above:

| Rule | Condition | Severity |
|------|-----------|----------|
| UniFi Console Backup Job Failed | `kube_job_status_failed > 0` for `unifi-backup-[0-9]+` with `reason!="DeadlineExceeded"` | warning |
| UniFi Console Backup Job Stale | Last success (or CronJob creation, if never successful) more than 14 days ago | warning |

Both route to `Slack - CronJobs` via the existing `alertname =~ ".*Job.*|.*Schedule.*|.*Running Too Long"` match — both titles contain "Job".

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
      image: alpine:3.24
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
