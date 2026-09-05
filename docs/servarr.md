# Servarr Media Stack

**Reference.** Read this when working on Transmission, Sonarr, Radarr, Prowlarr, Bazarr, or Overseerr. For NAS scheduling constraints these services share, see [nas-k3s.md](nas-k3s.md).

The servarr stack automates media acquisition, organization, and streaming. Each component is a separate Kustomize resource under `servarr/`.

## Data Flow

```
User → Overseerr (request UI)
         ↓
Sonarr / Radarr (search & monitor)
         ↓
Prowlarr (indexer management)
         ↓
Transmission (download via WireGuard VPN)
         ↓
NFS media library (/tv, /movies)
         ↓
Plex (streaming)
```

## Components

| Service | Image | Port | Domain | Storage |
|---------|-------|------|--------|---------|
| Transmission | linuxserver/transmission:4.1.1 | 9091 | transmission.home.bstjohn.net | config: local-path (5 GB), downloads: NFS (1 TB). |
| Sonarr | linuxserver/sonarr:4.0.17 | 8989 | sonarr.home.bstjohn.net | config: local-path, media: NFS (/tv), downloads: NFS |
| Radarr | linuxserver/radarr:6.0.4 | 7878 | radarr.home.bstjohn.net | config: local-path, media: NFS (/movies), downloads: NFS |
| Prowlarr | linuxserver/prowlarr:2.3.0 | 9696 | prowlarr.home.bstjohn.net | config: local-path |
| Bazarr | linuxserver/bazarr:1.5.6 | 6767 | bazarr.home.bstjohn.net | config: local-path |
| Overseerr | linuxserver/overseerr:1.35.0 | 5055 | overseerr.home.bstjohn.net | config: local-path |

All services run with `PUID=1000`, `PGID=1000`, `TZ=Europe/London`.

## Transmission + WireGuard VPN

Transmission is the most complex deployment — a two-container pod with a WireGuard VPN sidecar.

### Pod Architecture

```
┌─────────────────────────────────┐
│ Transmission Pod                │
│                                 │
│  ┌─────────────┐ ┌───────────┐ │
│  │ wireguard   │ │transmission│ │
│  │ (sidecar)   │ │           │ │
│  │ NET_ADMIN   │ │ Port 9091 │ │
│  │ SYS_MODULE  │ │ (web UI)  │ │
│  │ privileged  │ │           │ │
│  └─────────────┘ └───────────┘ │
│         ↕ shared network ns     │
└─────────────────────────────────┘
```

Both containers share the pod network namespace. All Transmission traffic exits through the WireGuard tunnel to Mullvad.

### VPN Configuration

| Parameter | Value |
|-----------|-------|
| Provider | Mullvad (ie-dub wg) |
| Endpoint | 146.70.189.2:51820 |
| Peer port | 51413 (TCP/UDP) |

The WireGuard config is stored in Kubernetes secret `transmission-wireguard` (key: `wg0.conf`). The config includes:
- `AllowedIPs = 0.0.0.0/0` — routes all traffic through tunnel
- Kill switch via `PostUp`/`PostDown` iptables rules — drops all non-tunnel traffic if VPN goes down
- `PersistentKeepalive = 25` — keeps tunnel alive

### Security Layers

1. **WireGuard kill switch** — iptables rules in the WireGuard config (`PostUp`/`PostDown`) drop all non-tunnel, non-LAN traffic
2. **NetworkPolicy** (`networkpolicy.yaml`) — Kubernetes-level isolation:
   - Ingress: only port 9091 (web UI) from Traefik, truenas-gate, Sonarr/Radarr/Prowlarr, and Gatus
   - Egress: DNS (port 53 to kube-dns) + WireGuard (UDP 51820 to Mullvad endpoint only)
3. **Tunnel-to-LAN block** — pod iptables drops FORWARD traffic from the tunnel to private IP ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
4. **Privileged mode** — required for WireGuard (NET_ADMIN, SYS_MODULE, /lib/modules hostPath)

### Secrets

| Secret | Keys | Purpose |
|--------|------|---------|
| `transmission-wireguard` | `wg0.conf` | WireGuard tunnel config |

## Authentik ForwardAuth Integration

Sonarr, Radarr, Prowlarr, and Bazarr are protected by Authentik's ForwardAuth middleware. These \*arr apps manage authentication via `/config/config.xml` on disk, and their built-in auth UI must be disabled so ForwardAuth can take over cleanly.

Transmission is in the same model but disables its own auth differently — there is no `config.xml` to patch. Instead the `set-seed-limits` init container pins `rpc-authentication-required: false` in `settings.json`, and the Deployment sets no `USER`/`PASS` env vars. The root cause that made this necessary: the `transmission-forward-auth-home` proxy provider had `intercept_header_auth` at its default `true`, so the outpost consumed the browser's `Authorization: Basic` header and validated it against Authentik instead of passing it through to Transmission — the app never saw the credentials and basic auth 401-looped through the ingress even with correct credentials. The blueprint now pins `intercept_header_auth: false` (#921).

Each of these deployments has an **init container** (`set-external-auth`) that runs before the main container and patches the app's config on every pod start. For Sonarr, Radarr, and Prowlarr this is `config.xml` (XML); for Bazarr it is `config/config.yaml`. The init container also deletes empty config files (produced by ungraceful shutdowns that truncate the file) so the app can regenerate a valid one.

For Sonarr and Radarr, the patched values are:

```xml
<AuthenticationMethod>External</AuthenticationMethod>
<AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>
<ApiKey>...</ApiKey>  <!-- pinned from servarr-apikeys secret -->
```

- `AuthenticationMethod: External` — tells the app not to handle its own login flow
- `AuthenticationRequired: DisabledForLocalAddresses` — suppresses auth redirects for in-cluster API calls (Prowlarr→Sonarr, Radarr→Sonarr, etc.)
- `ApiKey` — pinned to the value from the `servarr-apikeys` SOPS-encrypted secret; see [Inter-Service Communication](#inter-service-communication) below

The init container uses `sed` to either update the existing element or inject it before `</Config>` if absent. This is idempotent — safe to re-run on every restart.

**Traefik middleware**: Protected ingresses add `traefik.ingress.kubernetes.io/router.middlewares: default-authentik-auth@kubernetescrd`. Without the init container patch, ForwardAuth still protects the ingress but the app's own login page may also appear, confusing users or causing redirect loops.

**Overseerr** is excluded — it uses Plex native authentication, not ForwardAuth. See [authentik.md](authentik.md) for the full list of ForwardAuth-protected services.

## NetworkPolicies

ForwardAuth only protects the Traefik ingress path — on their own, ClusterIPs are reachable unauthenticated from any pod in the cluster. Sonarr, Radarr, Prowlarr, and Bazarr each have a `networkpolicy.yaml` restricting ingress on their app port to the `traefik` namespace plus the specific sibling pods that call them at runtime (Prowlarr↔Sonarr/Radarr indexer sync, Overseerr/Jellyseerr→Sonarr/Radarr, Bazarr→Sonarr/Radarr) and Gatus health checks. Transmission's existing `networkpolicy.yaml` ingress rule was similarly narrowed from "any namespace" to Traefik, the `truenas-gate` proxy, plus Sonarr/Radarr/Prowlarr/Gatus; its WireGuard egress lockdown is unchanged. This closes the gap where the *arr apps' internal auth is disabled in favour of ForwardAuth (see above) — without a NetworkPolicy, a direct ClusterIP request needed no forged header at all. The `truenas-gate` peer is load-bearing — `transmission`'s Ingress backend is `truenas-gate:80`, not the Transmission Service, so omitting it makes the web UI serve the "TrueNAS is asleep" wake page permanently (#771).

**Jellyseerr itself has no `networkpolicy.yaml` yet** (#818, raised but not implemented as of 2026-08-15) — every pod in the cluster can currently reach `jellyseerr:5055` directly, bypassing the ingress path. Egress needs no change: nothing restricts it today, and it must stay that way (TMDB/TheTVDB/image-CDN metadata lookups, plus the Authentik OIDC discovery endpoint). The decided design for the missing ingress policy: restrict port 5055 to the `traefik` namespace plus Gatus only — deliberately **not** Sonarr, Radarr, or Jellyfin, since Jellyseerr is a *client* of those APIs (it polls them outbound) and never receives inbound calls from them, unlike the ForwardAuth-protected \*arr apps above whose peer lists include each other.

**Health probes on the \*seerr apps.** Overseerr, Jellyseerr, and Seerr all probe `/api/v1/status/appdata`, never `/api/v1/status`. The latter performs an `api.github.com` lookup for its update check and blocks for ~5 s whenever external DNS is unavailable; with the Kubernetes default `timeoutSeconds: 1` this failed the startup probe 30 times in a row and put all three healthy pods into CrashLoopBackOff (#832). `/api/v1/status/appdata` is unauthenticated, does no network I/O, and returns in under 10 ms.

## NFS Storage Layout

All NFS storage is on the NAS at `192.168.0.128` (NixOS since 2026-07-27, formerly TrueNAS):

```
/mnt/SSD-POOL/           # exported as a whole; PV ssdpool-nfs-pv, PVC ssdpool-pvc
├── downloads/           # Transmission downloads — subPath: downloads (transmission only)
│   ├── complete/        #   sonarr+radarr reach it as /data/downloads
│   └── incomplete/
└── media/               # also exported narrowly as media-nfs-pv / media-soft-nfs-pv
    ├── TV/              # Sonarr root folder — /tv symlink -> /data/media/TV
    ├── Movies/          # Radarr root folder — /movies symlink -> /data/media/Movies
    ├── photos/          # Immich (media-pvc, subPath: photos)
    └── backups/         # immich-db-backup, forgejo-backup-offsite,
                         #   retired-servarr-config-2026-02/ (see below)
```

**Service config does not live on NFS.** Every servarr service takes `/config` from its own
node-local `local-path` PVC — `sonarr-local-config-pvc`, `radarr-local-config-pvc`,
`bazarr-local-config-pvc`, `prowlarr-local-config-pvc`, `overseerr-local-config-pvc`,
`transmission-local-config-pvc` (each 5Gi, defined in `apps/servarr/<service>/pvc.yaml`).
On disk these are `/var/lib/rancher/k3s/storage/pvc-*` on `k3s-nas`. They have **no backup** —
see [nas-k3s.md](nas-k3s.md) and issue #694.

### Retired pre-migration config directories

`/mnt/SSD-POOL/downloads/` used to hold NFS-backed config directories (`config`,
`config-bazarr`, `config-overseerr`, `config-pihole`, `config-prowlarr`, `config-radarr`,
`config-sonarr`, ~35 MiB total). Nothing has mounted them since config moved to local-path
PVCs; their newest file is dated **2026-02-11**. They were moved to
`/mnt/SSD-POOL/media/backups/retired-servarr-config-2026-02/` (issue #729).
(`config-pihole` is from the long-since-removed Pi-hole deployment — Pi-hole is not deployed anywhere in this cluster.)

**Do not use them for diagnosis.** `config/` contains a complete, plausible-looking
Transmission state — 16 `.torrent` files with matching resume files — that is five months
stale: a different set of titles from what is actually loaded, with payloads that now live
under `media/`, not `downloads/complete`. This snapshot sent the #727/#728 disk-space
investigation down a wrong path. The live Transmission state is in
`transmission-local-config-pvc`; read it with
`kubectl exec deployment/transmission -c transmission -- ls -la /config/torrents`.

Sharing one `st_dev` is not sufficient for hardlinking: `link(2)` requires both paths to be under the same **vfsmount**, and Kubernetes creates one bind mount per `volumeMounts` entry, so two `subPath` mounts of the same PVC are two vfsmounts — `do_linkat` still returns `EXDEV` across them even though `st_dev` matches (issue #1072). Sonarr and Radarr therefore mount `ssdpool-pvc` once at `/data`, with no `subPath`, and create `/tv`, `/movies` and `/downloads` as symlinks into it in their container entrypoint before `exec /init`, so the paths stored in their non-GitOps-managed databases stay valid. An `assert-hardlink` init container performs a real `ln` and fails the pod on `EXDEV`. Transmission keeps a plain `subPath: downloads` mount because it never links. `downloads` must stay a plain directory in the `SSD-POOL` root dataset — never its own ZFS dataset, never its own PV — or hardlinking breaks again. Bazarr and everything else still use the narrower `media` export via `media-pvc`/`media-soft-pvc`; consolidating them onto `ssdpool-pvc` is a **deliberately deferred** follow-up, not a forgotten one — see [nas-k3s.md](nas-k3s.md#pvc-consolidation-onto-the-media-export-deferred-not-rejected-1071) for why (it would mean migrating twice once `nixos-config#19` lands) and the constraints that apply when it does happen.

sanoid snapshots the `SSD-POOL` root dataset (7 daily / 2 monthly) and, since `downloads` moved into it, now covers `downloads/` too — deleted or failed torrents and partial imports stay pinned in a snapshot for up to two months even after they're gone from the live tree.

The PVCs (and their backing `PersistentVolume`s) are defined in `apps/servarr/shared-pvcs.yaml`, a standalone file not owned by any single service's kustomization. They were deliberately pulled out of Sonarr's/Transmission's individual manifests (PR #351) because Flux's `prune: true` garbage-collects resources that disappear from a Kustomization — removing or restructuring the "owning" service would have deleted PVCs that other services still depend on, destroying the media library and download directory. Any future shared NFS volume should follow this pattern rather than being owned by one service's directory.

### ZFS dataset flatten runbook (#727/PR #1070, record only — repeatable shape)

Consolidating `downloads` onto the `SSD-POOL` pool-root export (the change that made the vfsmount fix above possible) required a NAS-side ZFS step, because `SSD-POOL/downloads` was still its own dataset: under a pool-root export, `subPath: downloads` would have resolved to an empty mountpoint directory rather than the actual data, and Transmission would have started writing into a hidden path. Run by hand on the NAS, in order, **before** merging the PR that changes the PVC's `nfs.path`:

```bash
flux suspend kustomization apps -n flux-system
kubectl -n default scale deploy sonarr radarr bazarr transmission --replicas=0
zfs set mountpoint=/mnt/downloads-old SSD-POOL/downloads
exportfs -ra
mkdir -p /mnt/SSD-POOL/downloads
chown 1000:1000 /mnt/SSD-POOL/downloads
chmod 0777 /mnt/SSD-POOL/downloads
rsync -aHAX --info=progress2 /mnt/downloads-old/ /mnt/SSD-POOL/downloads/
diff <(cd /mnt/downloads-old && find . | sort) <(cd /mnt/SSD-POOL/downloads && find . | sort)   # must be empty
du -sh /mnt/downloads-old /mnt/SSD-POOL/downloads                                              # must match
kubectl -n default scale deploy sonarr radarr bazarr transmission --replicas=1
flux resume kustomization apps -n flux-system
# only after transmission shows its torrents healthy:
zfs destroy SSD-POOL/downloads
```

`flux suspend` is required because `apps` reconciles every 1 minute with `replicas: 1` pinned in Git — without suspending, Flux undoes the scale-down mid-`rsync`. `exportfs -ra` is required because the scaled-up pods stay bound to the old, narrower NFS export until the PR merges and the PVC's `nfs.path` changes — without re-exporting, they'd hold a stale NFS handle. **Gate before declaring done**: `stat -c "%d %n" /mnt/SSD-POOL /mnt/SSD-POOL/downloads` on the NAS must return the same device id for both paths — that's the actual proof the flatten worked, not just that the commands exited 0. Only `zfs destroy` the old dataset after confirming Transmission's torrents are healthy post-cutover.

This is the same maneuver [nas-k3s.md's deferred media-export consolidation](nas-k3s.md#pvc-consolidation-onto-the-media-export-deferred-not-rejected-1071) will need again once `nixos-config#19` moves `media` into its own dataset — reuse this runbook rather than re-deriving it.

## Downloads Janitor

`apps/servarr/downloads-janitor/` is a daily CronJob (01:30, `k3s-nas`) that finds — and, once
enabled, deletes — download data Transmission no longer owns. Nothing previously watched for
this: `RemoveCompletedDownloads` (see [Completed download cleanup](#completed-download-cleanup))
only reaps torrents Transmission still tracks and has finished seeding; a torrent removed from
Transmission without "delete data", a crashed or killed download, or a manual removal left its
files behind forever. Issue #1074.

**The three-way test.** An entry under `downloads/complete/`, `downloads/complete/<category>/` or
`downloads/incomplete/` is orphaned only if all three hold:

1. Its basename is absent from `transmission-remote`/RPC `torrent-get`. Matching is by
   **basename, not path** — an in-progress torrent reports `downloadDir=/downloads/complete`
   while its bytes are still sitting in `/downloads/incomplete`, so path matching would flag a
   live download as orphaned.
2. Every file under it has `nlink == 1`. Since #1072, a completed download that Sonarr/Radarr
   imported is hardlinked into the library, so `nlink > 1` is a reliable "already imported"
   marker; the whole entry is kept if any file in it has `nlink > 1`, leaking a little rather
   than risking a library copy's only inode neighbour.
3. Its newest mtime is older than `AGE_DAYS` (14).

**Fails closed.** Any Transmission RPC error, or a parsed torrent count that does not match
`session-stats`' `torrentCount`, aborts the run with a non-zero exit before the scan starts. An
empty or misparsed live set would make every download look orphaned, so the detector never falls
through to a scan on uncertain data.

**Category directories are scan roots, not candidates.** Transmission creates
`downloads/complete/radarr` and `downloads/complete/tv-sonarr` from the Sonarr/Radarr
download-client "category" setting. They are containers, so `CATEGORY_DIRS` (default
`"radarr tv-sonarr"`) lists them as additional scan roots: each is descended into, and no path
that is itself a root is ever a deletion candidate. Without this the scan's `-maxdepth 1` judged
the whole `complete/<category>` tree as one entry — one hardlinked file anywhere under it kept
everything (so `complete/` could never be cleaned), and an empty category directory untouched for
`AGE_DAYS` was itself swept, breaking Transmission's download path. Fixed in #1121. Add any new
category here when a new *arr download client is configured; names containing spaces are not
supported.

**NetworkPolicy warm-up.** The RPC handshake is retried every 5s for up to `RPC_WAIT_SECS` (120)
before the fail-closed verdict. `transmission-isolation` allows `app in (…, downloads-janitor)`,
but k3s's kube-router NetworkPolicy controller takes a few seconds to add a *new* pod IP to the
ipset behind that rule, and a denial on this cluster is an instant TCP reject rather than a drop
(`curl: (7) … after 1 ms: Could not connect to server`). A job pod that curls within ~1s of start
therefore lost that race on every run — the first scheduled run failed exactly this way, issue
#1084. Measured: the attempt at t=0 fails, the attempt at t≈6s succeeds. Any future short-lived
Job in `default` talking to a NetworkPolicy-protected Service needs the same retry.

**Per-run cap.** `MAX_ENTRIES` (5) and `MAX_KB` (100 GiB) bound how much a single run may delete;
exceeding either aborts with nothing deleted. Sanoid now snapshots the `SSD-POOL` root dataset
(7 daily / 2 monthly) and covers `downloads/` since it was flattened into that dataset, so
anything deleted stays pinned in a snapshot for up to two months — a cleanup that runs rarely and
deletes a lot at once is worse for a pool at 88% than one that runs often and deletes a little.

**`DRY_RUN`.** Now `"false"` — the janitor deletes. It shipped `"true"` so a human read the
first report before deletion was enabled; that report landed on 2026-09-04 (#1121: two entries
under `incomplete/` totalling 512 MiB, last touched 2026-03-11, `nlink == 1`, absent from a live
set of zero torrents). Set `DRY_RUN` back to `"true"` in
`apps/servarr/downloads-janitor/cronjob.yaml` to re-arm report-only mode; in that mode the job
logs every `ORPHAN:` candidate and exits non-zero so the alert surfaces the report.

**Alerting**: `servarr-downloads-janitor-job-failed` and `servarr-janitor-schedule-missed`
in `apps/monitoring/kube-prometheus-stack.yaml` — see [monitoring.md](monitoring.md#cronjob-alerts).

**Mount**: like Sonarr and Radarr, it mounts `ssdpool-pvc` once at `/data` with no `subPath`, per
the rule in `apps/servarr/shared-pvcs.yaml` — the janitor must see the same `st_dev`/vfsmount as
Sonarr and Radarr for its `nlink` test to mean anything.

## Inter-Service Communication

Services communicate via Kubernetes DNS within the cluster:

| From | To | Address |
|------|-----|---------|
| Sonarr/Radarr | Transmission | `transmission.default.svc.cluster.local:9091` |
| Prowlarr | Sonarr | `sonarr.default.svc.cluster.local:8989` |
| Prowlarr | Radarr | `radarr.default.svc.cluster.local:7878` |
| Overseerr | Sonarr | `sonarr.default.svc.cluster.local:8989` |
| Overseerr | Radarr | `radarr.default.svc.cluster.local:7878` |

Prowlarr pushes indexers to Sonarr/Radarr via their APIs (configured in Prowlarr → Settings → Apps).

The Sonarr and Radarr API keys are pinned via the `servarr-apikeys` SOPS-encrypted secret and applied to `config.xml` by each app's `set-external-auth` init container. This prevents the key from drifting when an ungraceful shutdown truncates `config.xml` and the app regenerates a fresh random key — which would otherwise break the Prowlarr, Overseerr, and Bazarr integrations that store these keys.

### Config self-heal (root folder + download client)

Unlike the API key (stored in `config.xml`), Sonarr/Radarr **root folders** and **download clients** live in the app database (`sonarr.db` / `radarr.db`), which is not GitOps-managed. An ungraceful shutdown that resets the database loses both: Prowlarr automatically re-syncs indexers, but nothing restores the root folder or download client. The symptom is silent — with no root folder, every Overseerr push fails and no series/movies are ever created; with no download client, grabs have nowhere to go and nothing downloads.

To make these self-healing, each app's Deployment runs a `config-reconciler` sidecar (curl) that polls the local API and re-creates the root folder (`/tv` for Sonarr, `/movies` for Radarr) and the Transmission download client if missing. Both POSTs are idempotent — skipped when already present — so the sidecar is a no-op in steady state and re-provisions only after a reset. It authenticates Sonarr/Radarr API calls with the pinned key from `servarr-apikeys`. Transmission has no RPC auth (#921), so the download-client body it registers carries no credentials.

Both Deployments run the *same* reconcile loop: it lives in `apps/servarr/reconcile-config.sh` and is mounted read-only at `/scripts/reconcile.sh` from the `servarr-reconciler-script` ConfigMap, which `apps/kustomization.yaml` generates with a name-suffix hash — so editing the script changes both pod templates and Flux rolls Sonarr and Radarr automatically. The per-service differences are passed as env vars: `API_PORT`, `ROOT_FOLDER`, `CATEGORY_FIELD`, `CATEGORY_VALUE`.

The sidecar also rewrites the **entire** download-client body on an **already-present** Transmission client, via `PUT /api/v3/downloadclient/{id}?forceSave=true` (the `forceSave` flag skips the connection test, so the update still lands while Transmission or the NAS is unreachable). It triggers a rewrite when `removeCompletedDownloads` / `removeFailedDownloads` is not `true`. Otherwise it is a no-op, so steady state stays write-free. Because the rewritten body is the same desired-state JSON used to create the client, a rewrite also resets any field the sidecar doesn't manage — `recentTvPriority`, `olderTvPriority`, `addPaused`, `tvImportedCategory`/`movieImportedCategory`, `tvDirectory`/`movieDirectory` — to their defaults; all of these are at their defaults today. The sidecar image is `curlimages/curl` rather than `busybox` because BusyBox `wget` cannot issue a PUT at all — it supports only GET and `--post-data`/`--post-file`.

### Completed download cleanup

Removal of a completed download only fires when **both** halves are in place: the \*arr removal flags above, **and** a seed limit in Transmission. Sonarr/Radarr will only remove a torrent that has reached its seed goal, so with seeding unbounded the removal flags alone never trigger (issue #728 — `downloads/complete` had grown to 117 GiB); the limit is now `ratio-limit: 0.0`, i.e. stop at 100%.

Transmission's `settings.json` lives on a non-GitOps local-path PVC, so `apps/servarr/transmission/deployment.yaml` carries a `set-seed-limits` init container that pins `ratio-limit: 0.0` / `ratio-limit-enabled: true` and `idle-seeding-limit: 30` / `idle-seeding-limit-enabled: true` on every pod start. A ratio limit of `0.0` means **we do not seed**: Transmission's seed goal is `size × ratio-limit`, so the goal is already met at 100% and the daemon stops the torrent the moment it completes, marking it `isFinished` / `stopped` (#1078). That is the state Sonarr/Radarr require before they will import and remove it, so cleanup fires promptly rather than after a 2× ratio. The idle limit remains only as a backstop for a torrent carrying a per-torrent seed-ratio override. The init container runs before the daemon, which is the only time `settings.json` is read, and the patch is idempotent. On a fresh install `settings.json` does not exist yet, so the limits apply from the second pod start onward — the same behaviour as `set-external-auth`.

## TrueNAS Gate

Transmission is routed through `truenas-gate` so users see a wake page instead of errors when TrueNAS is offline. Sonarr, Radarr, and other servarr services connect directly — their pods wait for NFS and resume automatically. See [truenas-gate.md](truenas-gate.md).

## Availability Notes

- **Transmission, Sonarr, Radarr** depend on NFS from the NAS — pods won't fully start if the NAS is offline
- **Prowlarr, Bazarr, Overseerr** use local-path only — available regardless of NAS state
- Config storage is `local-path` for all services — survives NAS downtime. Config has not been
  NFS-backed since early 2026; see [Retired pre-migration config directories](#retired-pre-migration-config-directories)

## Config backups

Every servarr config PVC is node-local `local-path` storage, which means it is tied to the disk of whichever node the service is pinned to and has no inherent redundancy. In July 2026 the storage VM hosting Sonarr, Radarr, Bazarr, Transmission and Jellyfin was destroyed during the TrueNAS → NixOS migration; those configs were recovered only because the underlying ZFS volume happened to survive intact.

Sonarr, Radarr, Bazarr and Transmission are now backed up nightly by the `config-backup` CronJob (`apps/config-backup/cronjob.yaml`) at 02:00, to `/mnt/SSD-POOL/media/backups/config/<app>/`, 14 archives retained per app. SQLite databases are copied via the online backup API rather than tarred live, so the archives are consistent. Jellyfin moved to the separate `config-backup-players` CronJob (on `k3s`) as part of the #800 cutover — see [config-backups.md](config-backups.md). Prowlarr and Overseerr are **not yet** covered; now that `config-backup-players` also runs on `k3s`, the original two-node blocker no longer applies and adding them is just an `APPS` list change.

See [config-backups.md](config-backups.md) for the exclusion list, alerting, and the restore runbook.

## Additional Documentation

- `servarr/SETUP.md` — Step-by-step guide for connecting all services together
