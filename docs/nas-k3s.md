# NAS Storage Node

> **Partially superseded by [#800](https://github.com/St-John-Software/fleet-infra/issues/800) (2026-08-13).** Plex and Jellyfin no longer run on this node — they moved to `k3s` behind a `soft` NFS media mount so they stay up while the NAS sleeps. Everything below still describes the *write* tier accurately. See [nas-app-tier-migration.md](nas-app-tier-migration.md).

## Why

**Node pinning here is a hard constraint, not a locality optimisation.** The NAS box is deliberately powered off most of the time (only the main `k3s` node runs 24/7), and pinning is what stops these services pretending to run without the storage they need.

That still holds for the **write** tier — Sonarr, Radarr, Bazarr, Transmission, Immich, `immich-db-backup`, `config-backup` and `containerd-gc-storage`. They all mount NFS `hard` by necessity: a silently lost write on a `soft` NFSv3 mount is unacceptable for imports, torrents and the photo set. Unpinning them would not make them available while the NAS sleeps, only relocate hung mounts onto the control-plane node.

It does **not** hold for Plex and Jellyfin. They only ever read the media share, so since #800 they run on `k3s` against `media-soft-pvc` — a second PV over the *same* export with `soft,timeo=50,retrans=2`. A pod that is already running gets `EIO` when the NAS disappears mid-session instead of blocking in D-state, so their web UIs (and Plex's `/identity`, which Overseerr authenticates against) keep working while the NAS is off; only playback fails. Their library scanners must stay disabled — an empty-looking tree is how a scanner deletes a library. See [nas-app-tier-migration.md](nas-app-tier-migration.md).

Pods accessing NFS mounts fail cleanly when the NAS is offline: the node goes `NotReady`, pods are evicted after ~5 minutes, and the `nodeSelector` prevents them rescheduling elsewhere. When the NAS comes back online, the node reconnects, pods are scheduled again, and everything resumes automatically — no stuck `ContainerCreating`.

A `NotReady` storage node is normal here, not a fault. Don't propose automatically deleting or pruning `NotReady` node objects as a general cleanup — the one time this node object was deleted (#695), it was because the underlying VM was permanently gone (replaced by the NixOS bare-metal rebuild), not because it was merely unreachable.

## Host OS: NixOS, not TrueNAS (migrated 2026-07-27)

Despite the node name (`k3s-nas`) and this doc's title, **the physical NAS box no longer runs TrueNAS.** It was reinstalled with **NixOS 26.05** on 2026-07-27 (issue #690, St-John-Software/nixos-config#17/#21), replacing TrueNAS CORE 13.0-U6.8. Two consequences that matter for anyone working on this node going forward:

- **k3s now runs directly on the bare-metal NixOS host**, not inside a nested VM. Previously, TrueNAS CORE hosted a `bhyve` VM (`k3s-nas`) as the k3s worker, and Plex ran in a separate FreeBSD `iocage` jail. Both nested-virtualization layers existed only because TrueNAS's FreeBSD base was the wrong shape for the job (no Linux driver for the onboard Realtek RTL8125B NIC, no native container runtime for k3s). NixOS removes the need for either layer: k3s is a first-class NixOS module (`services.k3s`) running on the host, and Plex is a regular in-cluster Deployment (see [Plex](apps-overview.md); it was pinned to this node until #800 moved it to `k3s`).
- **The node's IP, `192.168.0.128`, is now a static address declared in the NixOS config** (`hosts/nas/default.nix` in the sibling `nixos-config` repo), not a router DHCP reservation. The prior DHCP-reservation setup silently drifted to `.126` on a reboot at one point, leaving all six workloads on this node stuck in `ContainerCreating` for 17 days (undetected because Grafana suppresses `k3s-nas` node-offline noise — see [monitoring.md](monitoring.md)) and making the last Immich DB backup before the rebuild 17 days stale. Pinning the IP in the OS config (with `networking.useDHCP = true` left on as a fallback in case an added HBA renumbers the NIC) closes that failure mode.

Why this repo (fleet-infra) doesn't show a corresponding manifest change: the host OS, k3s installation, and NIC/IP config for this node are managed declaratively in the separate `nixos-config` repo, not here — this repo only ever saw the node as a k3s worker with a label and taint, regardless of what's underneath it.

**Operational gotchas from the migration** (useful if this node ever needs rebuilding again):
- Kubelets cannot self-assign `kubernetes.io/*` labels (privilege-escalation guard) — the taint can be set from the node/OS config, but the `node-role.kubernetes.io/storage=true` label must still be applied from the control plane (see "Node label" below). This was already true under the old Ubuntu-VM setup too.
- NixOS has no `/lib` — Transmission's WireGuard sidecar mounts `/lib/modules` as a `hostPath`, which doesn't exist on NixOS. Fixed with a `systemd.tmpfiles.rules` symlink into `/run/booted-system/kernel-modules/lib/modules` plus `boot.kernelModules = [ "wireguard" ]` (the symlink lets the container find the module; the host still has to load it — `CAP_SYS_MODULE` only works against the host kernel).
- `nixpkgs`' current k3s release can run ahead of the control plane's pinned version, exceeding the supported kubelet/API-server skew (kubelet may be older than the server, never newer). Pin the k3s package version explicitly (e.g. `services.k3s.package = pkgs.k3s_1_34`) to match the server.
- `RequiresMountsFor` on the `k3s` systemd unit (pointing at the ZFS pool mount) stops the agent starting before its storage is present — the systemd-level version of the node-pinning constraint above.

**Still outstanding from the migration** (per the owner's own notes — not yet done, don't assume otherwise): no off-box backup exists for the NAS's data pool; the `media`/`backup` paths are plain directories rather than ZFS datasets (blocking per-share snapshots and incremental replication). The node-local config PVC gap called out here previously is closed — see the `config-backup` CronJob in [config-backups.md](config-backups.md), which does SQLite-consistent backups (WAL sidecars included, not just the main `.db` file) of the four servarr config PVCs on this node — Plex's and Jellyfin's moved to `k3s` with them in #800 and are covered by a second CronJob.

## Planned: NFS → authenticated SMB migration (#816 — decided, not started)

The owner has decided to replace NFSv3 with authenticated SMB/CIFS for every NAS-backed PV in this table. NFSv3 as currently exported (`rw,no_root_squash` to the whole `192.168.0.0/24`) is unauthenticated — source-IP trust, client-asserted uids — and that is the problem being fixed, not performance or reliability. Kerberized NFSv4 was considered and rejected as disproportionate for a home network; the chosen mechanism is `csi-driver-smb` against a dedicated `k3s` service account on the NAS (NAS-side account and share creation is a separate `nixos-config` change). **Nothing in this repo reflects this migration yet as of 2026-08-15** — all PVs below are still NFS; don't assume `csi-driver-smb` is installed or that any SMB PV exists.

Constraints that matter for whoever implements this, established before any plan was written:

- **PV specs are immutable in this repo's convention** (see #727) — the migration is new PVs/PVCs and workload re-binds, never in-place edits of the existing NFS PVs.
- **`nodeAffinity` and the node names `k3s-nas` / `ryzen` are load-bearing** and must carry over unchanged to any new PV — see "The name `k3s-nas` is historical and load-bearing" above.
- **The hardlink requirement is the hard part.** Sonarr/Radarr import from Transmission's downloads via `link(2)`, which is why media and downloads currently share one PV/`subPath` design (one `st_dev`). Any SMB layout must preserve that — one share, one mount, `subPath` (not `volumeAttributes.subDir`, which would create a second CIFS superblock with a different `st_dev`) — and `link(2)`-over-CIFS must be verified against a real mount before any cutover: a silent `EXDEV` fallback to copying cost ~86 GiB of duplication the last time this class of assumption was wrong (nixos-config#51).
- Sequencing is strict: the NAS-side SMB share and service account land first (`nixos-config`), then this repo cuts over and verifies (including the hardlink check and a Plex/Jellyfin playback check) with both protocols serving during the transition, and only after that do the NFS exports get removed.

## Architecture

Three-node k3s cluster (this doc covers the NAS/storage node; see [gpu-k3s.md](gpu-k3s.md) for the GPU worker node):

| Node | Role | Address | Services |
|------|------|---------|---------|
| `k3s` (Debian 12) | control-plane + worker | 192.168.0.251 | Traefik, Flux, Gatus, Homepage, Authentik, monitoring, etc. |
| `k3s-nas` (NixOS 26.05, the NAS host itself) | worker | 192.168.0.128 (static, pinned in NixOS config) | Sonarr, Radarr, Bazarr, Transmission, Immich (all 4 containers), immich-db-backup, config-backup |
| GPU worker (`ryzen`) | worker | 192.168.0.69 | Ollama, Whisper (see [gpu-k3s.md](gpu-k3s.md)) |

The name `k3s-nas` is historical and load-bearing: `local-path` PVs pin to it by immutable `nodeAffinity`, so any future rebuild must re-register the node under this same name (see "Replacing the node" below).

The NAS node carries a label and taint that pin NFS-dependent (and NAS-dependent) services to it:

```
label: node-role.kubernetes.io/storage=true
taint: node-role.kubernetes.io/storage=true:NoSchedule
```

Services not in the table above continue to run on the main node and are unaffected.

## HTTPS Access

No change. Traefik runs on the main node and handles all ingress. k3s CNI (Flannel) routes traffic across nodes transparently — existing `*.home.bstjohn.net` URLs continue to work unchanged.

## Services on the Storage Node

| Service | NFS Volumes | Local PVCs |
|---------|------------|------------|
| Sonarr | media-pvc (TV), transmission-downloads-pvc | sonarr-local-config-pvc (5Gi) |
| Radarr | media-pvc (Movies), transmission-downloads-pvc | radarr-local-config-pvc (5Gi) |
| Bazarr | media-pvc (TV + Movies) | bazarr-local-config-pvc (5Gi) |
| Transmission | transmission-downloads-pvc | transmission-local-config-pvc (5Gi) |
| Immich (server, ML, postgres, valkey) | media-pvc (photos) | immich-postgres-pvc (10Gi), immich-ml-cache-pvc (10Gi) |
| immich-db-backup (CronJob) | media-pvc | — |
| config-backup (CronJob) | media-pvc | mounts the four servarr config PVCs above |
| containerd-gc-storage (CronJob) | — | — |

Plex and Jellyfin used to be on this list. Since #800 they run on `k3s` against `media-soft-pvc`, with their `plex-config` / `jellyfin-config` `local-path` PVCs on that node and their own `config-backup-players` CronJob — see [nas-app-tier-migration.md](nas-app-tier-migration.md).

Every "Local PVC" above is a `local-path` volume under `/var/lib/rancher/k3s/storage/` on this
node. None of these services reads config from the NFS pool — the `config*` directories that used
to sit in `/mnt/SSD-POOL/downloads/` are a frozen 2026-02 snapshot, now parked in
`/mnt/SSD-POOL/media/backups/retired-servarr-config-2026-02/` (issue #729). See
[servarr.md](servarr.md#retired-pre-migration-config-directories).

## Provisioning

The node is declared in the sibling `nixos-config` repo (`hosts/nas/default.nix`), not here — this repo only ever sees it as a k3s worker with a label and taint. Provisioning is `nixos-rebuild switch` on the NAS host; there is no install script to run from this repo.

## Node label — reapply by hand

Kubelets cannot self-assign `kubernetes.io/*` labels — passing `--node-label=node-role.kubernetes.io/storage` makes k3s refuse to start outright. The taint is declared in `nixos-config` and applies automatically; the label does not and must be applied from the control plane after the node (re)joins:

```bash
kubectl label node k3s-nas node-role.kubernetes.io/storage=true
```

The label lives only on the Node object — deleting that object loses it, and every `nodeSelector` in this repo depends on it.

## Replacing the node

1. `kubectl delete node k3s-nas` from the control plane — **before** the rebuilt agent joins, not after. Re-registering under the same name inherits `SchedulingDisabled` left by a prior drain.
2. `nixos-rebuild switch` on the NAS host.
3. Re-apply the label (above).
4. `kubectl get nodes -o wide` — confirm `Ready` with the label and taint present.

## Offline Behaviour

When the NAS host shuts down:

1. k3s agent disconnects — node transitions to `NotReady`
2. After the default pod eviction timeout (~5 minutes), pods are evicted
3. Evicted pods cannot reschedule elsewhere (nodeSelector constrains them to the storage node)
4. `truenas-gate` shows the wake page for affected services, and serves it unconditionally at `wake.home.bstjohn.net` (Plex and Jellyfin stay up, so they no longer fall through to the gate — see [truenas-gate.md](truenas-gate.md))

When the NAS comes back online:

1. NAS host boots, k3s agent reconnects
2. Node returns to `Ready`
3. Pods are scheduled on the storage node and start normally
4. NFS volumes mount locally (no network hop)

This is expected, steady-state behaviour, not an incident — the NAS spends most of its time off. See "Why" above.

## DiskPressure Recovery

**Symptom**: pods on `k3s-nas` cycling through `Error` / `Evicted` / `ContainerStatusUnknown` / `Pending`; `kubectl describe node k3s-nas` shows `DiskPressure: True` and a `node.kubernetes.io/disk-pressure:NoSchedule` taint. Node-exporter on `k3s-nas` may also get evicted, which is why this repo pins it to `system-node-critical` so Grafana keeps receiving node metrics during the incident.

**Immediate remediation** (unblocks the cluster in under a minute):

```bash
# 1. SSH to the NAS host
ssh brendan@192.168.0.128

# 2. Check free space
df -h /

# 3. Force an image prune (run from the host, not inside a pod)
sudo crictl rmi --prune

# 4. Refresh kubelet's cached capacity. DiskPressure uses live statfs() so the
#    pressure condition will clear without this, but Node.status.capacity.ephemeral-storage
#    stays stale until the agent restarts. Optional — skip if pressure has cleared.
sudo systemctl restart k3s

# 5. Confirm DiskPressure has cleared (from the control plane, not k3s-nas)
kubectl describe node k3s-nas | grep -E 'DiskPressure|Taints'
```

Root is ext4 on NVMe via `disko.nix` — there is no LVM on this host, so growing the disk is a `nixos-config` change (repartition/resize in `disko.nix` + `nixos-rebuild switch`), not `lvextend`/`resize2fs`.

**Long-term prevention** (already in place):
- `containerd-gc-storage` CronJob runs daily at 04:30 on `k3s-nas`, pruning unused images. It tolerates both the `storage` taint and the `disk-pressure` taint, so it self-heals even when the node is already under pressure. The `containerd-gc-storage-job-failed` alert requires the node to have been continuously Ready for 26 hours before firing, so multi-day NAS downtime followed by power-on will not produce a false positive — the next scheduled 04:30 Europe/London run is given a chance to clear any stale failed Job first. The job resolves `crictl` through an explicit `HOST_PATH` that includes `/run/current-system/sw/bin`, because `k3s-nas` runs NixOS and `nsenter` inherits the container's PATH into the host mount namespace, where `/usr/local/bin/crictl` does not exist.
- Grafana alerts `NodeDiskPressure`, `NodeFilesystemAlmostFull` (15%), and `NodeFilesystemCritical` (5%) fire to Slack and GitHub Issues before pods start cycling.
- node-exporter is pinned to `system-node-critical` so it survives eviction and keeps feeding Prometheus.

## PVC Expansion on the Storage Node

The `local-path` provisioner on the storage node (`k3s-nas`) **does not support online volume expansion**. Unlike the main node where `allowVolumeExpansion: true` allows resizing a PVC in place, resizing a local-path PVC on `k3s-nas` requires a manual backup-delete-recreate procedure.

**Procedure** (for any `local-path` PVC bound to `k3s-nas`):

1. Find the hostPath directory for the PVC:
   ```bash
   kubectl get pvc <pvc-name> -n default -o jsonpath='{.spec.volumeName}'
   # Data lives at /var/lib/rancher/k3s/storage/<volume-name>/ on k3s-nas
   ```
2. Scale down the workload to zero replicas.
3. Back up the config directory from the node (SSH to `192.168.0.128`):
   ```bash
   cp -a /var/lib/rancher/k3s/storage/pvc-<volume-name>/ /tmp/<service>-config-backup/
   ```
4. Delete the existing PVC: `kubectl delete pvc <pvc-name> -n default`
5. Update the PVC manifest to the new size and apply it (or merge the PR so Flux applies it).
6. Get the new volume name and restore from backup:
   ```bash
   kubectl get pvc <pvc-name> -n default -o jsonpath='{.spec.volumeName}'
   cp -a /tmp/<service>-config-backup/. /var/lib/rancher/k3s/storage/pvc-<new-volume-name>/
   ```
7. Scale the workload back up and verify.

**Critical**: Complete the backup (step 3) before deleting the PVC. The provisioner removes the hostPath directory when the PVC is deleted. Merge the manifest PR either before step 4 (so Flux creates the new PVC from the updated spec) or after step 5.

## k3s Version Sync

The agent must run a k3s version compatible with the server (kubelet must not be newer than the API server). Check the current server version:

```bash
k3s --version
```

The agent's version is pinned in `nixos-config` (`services.k3s.package = pkgs.k3s_1_34`, currently 1.34.9 against a 1.34.3 server — nixpkgs' unpinned default would exceed the supported skew). When upgrading, bump the control plane first, then bump the pinned package in `nixos-config` and run `nixos-rebuild switch` on the NAS host.

## WireGuard (Transmission)

Transmission uses a WireGuard sidecar for VPN. NixOS has no `/lib`, so the sidecar's `hostPath` mount of `/lib/modules` doesn't exist by default. `nixos-config` fixes this with a `systemd.tmpfiles.rules` symlink into `/run/booted-system/kernel-modules/lib/modules`, plus `boot.kernelModules = [ "wireguard" ]` to load the module on the host — the symlink lets the container find the module, but the host still has to load it (`CAP_SYS_MODULE` only works against the host kernel). Verify:

```bash
lsmod | grep wireguard
```

If missing, the fix belongs in `nixos-config`, not on the running host — `modprobe`/`/etc/modules-load.d` edits here won't survive the next `nixos-rebuild switch`.
