# NAS App Tier Migration (#800) — Plex and Jellyfin cutover runbook

One-off runbook for moving Plex and Jellyfin off the storage node (`k3s-nas`) onto the always-on control-plane node (`k3s`). Run it once, in order. Once the cutover is done this document is history, not a procedure — but keep it, because step 7 describes settings that must stay set.

## Why only these two

Plex and Jellyfin are pure *readers* of the media share. With a `soft` NFS mount an already-running pod gets `EIO` when the NAS sleeps mid-session and keeps serving everything that does not touch the disk — including Plex's `/identity`, which is what Overseerr signs in against.

Everything else on `k3s-nas` writes: Sonarr, Radarr, Bazarr, Transmission, Immich, `immich-db-backup` and `containerd-gc-storage`. They keep `hard` mounts by necessity — a silently lost write on a `soft` NFSv3 mount is unacceptable for imports, torrents and the photo set — so moving them would not make them available during NAS sleep. It would only relocate hung mounts onto the control-plane node. They stay pinned. See [nas-k3s.md](nas-k3s.md).

`k3s-nas` also stays in the cluster: its `NotReady` → evict → reschedule-on-wake behaviour is the fail-clean mechanism for that write tier.

## Preconditions

On `k3s`:

```bash
df -h /var/lib/rancher/k3s/storage     # need >= 40 GiB free
kubectl describe node k3s | grep -A6 Allocated
```

Plex adds a 6Gi memory limit and Jellyfin a 4Gi one; requests are 512Mi each. Actual disk need is ~11G (Plex) + ~2G (Jellyfin), but `local-path` does not enforce claim size, so leave headroom. If either check fails, stop.

## Cutover

**1. Wake the NAS.** Confirm `kubectl get node k3s-nas` shows `Ready`.

**2. Suspend Flux, then stop both players.** The `apps` Kustomization reconciles every 1 minute with `prune: true`, and both Deployments declare `replicas: 1` in Git — left running, Flux reverts the scale-down below within a minute. Suspending first makes it stick for the whole procedure:

```bash
flux suspend kustomization apps
kubectl scale deploy/plex deploy/jellyfin --replicas=0
```

**3. Take the pre-cutover backup.** These tarballs become the only copy of both configs — step 4 destroys the originals.

```bash
kubectl create job --from=cronjob/config-backup config-backup-precutover
kubectl wait --for=condition=complete job/config-backup-precutover --timeout=60m
kubectl logs job/config-backup-precutover
```

> Run this **before** merging the PR. On `main` the `config-backup` CronJob no longer covers Plex and Jellyfin — `config-backup-players` does, and that Job cannot exist until the PR is merged. If the PR has already merged, use `--from=cronjob/config-backup-players` instead.

Verify both archives, and note the `STAMP` (`YYYYmmdd-HHMMSS`) from the filenames:

```bash
kubectl exec deploy/sonarr -- ls -lt /media/backups/config/plex/ /media/backups/config/jellyfin/
kubectl exec deploy/sonarr -- tar -tzf /media/backups/config/plex/plex-config-<STAMP>.tar.gz \
  | grep -E 'Preferences\.xml|Plug-in Support/Databases/.*\.db'
```

Both patterns must match. `Preferences.xml` carries the server's `MachineIdentifier` — without it the restored Plex is a *new* server to plex.tv and to every paired client.

**4. Delete the config PVCs.**

```bash
kubectl delete pvc plex-config jellyfin-config
```

The `local-path` reclaim policy is `Delete`, so this **irreversibly destroys** the on-NAS copies. Do not run it until step 3 verified.

**5. Merge the PR.** Flux is still suspended, so nothing reconciles yet — review and CI wall-clock time no longer matters.

**6. Resume, restore, then start.**

```bash
flux resume kustomization apps
flux reconcile kustomization apps --with-source
kubectl scale deploy/plex deploy/jellyfin --replicas=0
```

The reconcile recreates both PVCs from the merged manifests (`WaitForFirstConsumer` schedules them on `k3s`) and reapplies both Deployments, which briefly races their replicas back to 1 — the immediate re-scale above stops the pods before they finish starting and write initial config into the empty volume. Re-suspend so Flux doesn't repeat that before the restore below finishes:

```bash
flux suspend kustomization apps
```

Then run the restore Job below once per app and scale each back to 1:

```bash
kubectl scale deploy/plex --replicas=1
kubectl scale deploy/jellyfin --replicas=1
```

Plex's first start after a restore upgrades the database and is slow. The existing `startupProbe` (`failureThreshold: 90`, i.e. 15 minutes) covers it — **do not interrupt it.**

**7. Runtime settings — mandatory, not optional.** A soft mount plus a sleeping NAS makes a library scanner see an empty tree. Left on defaults, the scanner concludes the media is gone and deletes the entries.

- **Jellyfin:** now **enforced automatically** by the `config-reconciler` sidecar
  in `apps/jellyfin/deployment.yaml` (#807). On every pod start and every 5
  minutes it clears all triggers on the *Scan Media Library* scheduled task
  (`Key: RefreshLibrary`) and sets `SaveLocalMetadata`, `EnableRealtimeMonitor`
  and `SaveTrickplayWithMedia` to `false` on every library. Nothing to do by
  hand — but it needs the `jellyfin-api-key` Secret to exist:

  ```bash
  # Jellyfin Dashboard > API Keys > "+" > name it "config-reconciler"
  kubectl create secret generic jellyfin-api-key \
    --from-literal=api-key=<key> -n default
  kubectl rollout restart deploy/jellyfin
  ```

  Without the Secret the sidecar logs `JELLYFIN_API_KEY is empty` and idles;
  Jellyfin itself is unaffected, but the settings go back to being manual.
  Check it with `kubectl logs deploy/jellyfin -c config-reconciler`.
- **Plex:** Settings → Library → uncheck *Scan my library automatically*, *Empty trash automatically after every scan*, and *Allow media deletion*. Still manual — no reconciler (see #807 stretch).

**8. Verify, then resume Flux.**

```bash
kubectl get pods -o wide -l app=plex
kubectl get pods -o wide -l app=jellyfin     # both should show node k3s
curl -sk https://plex.home.bstjohn.net/identity
```

Once both are healthy, resume normal reconciliation — this is what re-arms Flux's 1-minute drift correction for the rest of the cluster:

```bash
flux resume kustomization apps
```

Sign in to Overseerr (and Jellyseerr) to confirm Plex/Jellyfin auth still works. Then power the NAS down and confirm both pods stay `Ready` and both web UIs load, with playback failing with an error rather than hanging. `https://wake.home.bstjohn.net` should serve the wake page throughout.

## Restore Job

A documented one-off exception to the no-`kubectl apply` invariant — this Job restores data into a volume and has no business in Git. Substitute `APP` ∈ {`plex`, `jellyfin`}, `PVC` ∈ {`plex-config`, `jellyfin-config`}, `UID:GID` ∈ {`972:972`, `0:0`}, and the `STAMP` from step 3.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: restore-APP-config
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: restore
          image: alpine:3.22
          securityContext: {runAsUser: 0}
          command: [/bin/sh, -c]
          args:
            - |
              set -eu
              test -z "$(ls -A /config)" || { echo "target not empty"; exit 1; }
              tar -xzf /media/backups/config/APP/APP-config-STAMP.tar.gz -C /config
              chown -R UID:GID /config
          volumeMounts:
            - {name: config, mountPath: /config}
            - {name: media, mountPath: /media}
      volumes:
        - {name: config, persistentVolumeClaim: {claimName: PVC}}
        - {name: media, persistentVolumeClaim: {claimName: media-pvc}}
```

It mounts the **hard** `media-pvc`, not `media-soft-pvc` — a restore must not ride a mount that can return `EIO` mid-extract. The NAS therefore has to be awake for this step.

The `test -z "$(ls -A /config)"` guard is deliberate: extracting over a non-empty config directory overlays rather than replaces, which silently mixes two generations of database.

## What this changed

| | Before | After |
|---|--------|-------|
| Plex / Jellyfin node | `k3s-nas` | `k3s` (always on) |
| Their media mount | `media-pvc` (hard) | `media-soft-pvc` (soft, `timeo=50`, `retrans=2`) |
| Their config PVCs | `local-path` on `k3s-nas` | `local-path` on `k3s` |
| Their config backup | `config-backup` | `config-backup-players` (01:00, unpinned) |
| Behaviour while NAS asleep | evicted, unschedulable | up; playback fails with EIO, UI works |
| Gatus | alert-free (`media-services`, `optional`) | Slack alerts, ungrouped |
| Wake page | via each service's `error_page` | also at `wake.home.bstjohn.net` |

## Risks carried forward

- **Scanner deletion under a sleeping NAS** is the highest-consequence failure
  mode. For Jellyfin the step-7 settings are now re-applied by the
  `config-reconciler` sidecar, so a reinstall or settings reset self-heals
  within 5 minutes. For **Plex** step 7 is still manual — if it is ever
  reinstalled or its settings reset, re-apply it by hand.
- **Transcode load now lands on the control-plane node.** Plex's `cpu: 4000m` limit and `low-priority` priority class are what protect Traefik and Flux — do not raise either. If CPU transcode proves disruptive, that is the trigger for the separate GPU/NVENC follow-up, not for reverting this.
- **`ryzen` was not the destination**: its `nvidia.com/gpu` is fully allocated by Ollama + Whisper under `replicas: 2` time-slicing, so NVENC transcode needs a device-plugin change first.
- **Restarted-while-asleep pods** still sit in `ContainerCreating` until the NAS returns — a soft mount rescues a *running* pod, not a starting one. `wake.home.bstjohn.net` is the manual escape hatch.
- The players-backup false-positive risk flagged at cutover is closed — the schedule moved to 01:00 (ahead of the NAS's 03:03 nightly poweroff), the alert filters `reason="DeadlineExceeded"`, and `Config Backup (Players) Job Stale` (14 days) prevents a silently-dead backup hiding forever. See [config-backups.md](config-backups.md#alerting).

## Related

- [nas-k3s.md](nas-k3s.md) — the storage node, what is still pinned to it and why
- [config-backups.md](config-backups.md) — the two-CronJob split
- [truenas-gate.md](truenas-gate.md) — the wake page and its new hostname
