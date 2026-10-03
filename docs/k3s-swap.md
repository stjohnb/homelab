# k3s VM swap runbook

**Depth:** **Deep dive**
**Read this when:** changing swap on the unmanaged k3s VM.
**Read instead:** [infrastructure-overview.md](infrastructure-overview.md) for Flux-managed cluster configuration.

The k3s VM has a fixed 24 GiB memory allocation and currently uses a roughly
1 GiB swap partition. The VM root filesystem has ample free space for a
larger swapfile, but this is host state and is not managed by Flux.

## Add a swapfile

Run these commands on the `k3s` VM as root during a quiet period. Choose a
specific path and size; do not replace the existing swap partition.

```bash
fallocate -l 4G /swapfile-claws
chmod 600 /swapfile-claws
mkswap /swapfile-claws
swapon /swapfile-claws
printf '%s\n' '/swapfile-claws none swap sw 0 0' >> /etc/fstab
```

Verify with `cat /proc/swaps` and `free -h`. The existing partition should
remain enabled as well. Swap is an emergency pressure buffer: sustained
`pswpin`/`pswpout` activity will make the VM slow and is covered by the
`NodeSwapThrashing` alert.

## Kubernetes cgroup note

Adding VM swap does not automatically make it available to pods. The Claws
pod currently has `memory.swap.max=0`. Enabling Kubernetes pod swap requires a
separate kubelet/container-runtime configuration change and should be tested
on the staging workload first. Even if enabled, swap must not be used to pack
more workers into the Claws pod than its memory limit (10Gi as of #1469) can
hold headroom for — see [apps-overview.md](apps-overview.md#claws) for why
`CLAWS_MAX_WORK_WORKERS`, the per-worker watchdog, and the container limit
must move together.
