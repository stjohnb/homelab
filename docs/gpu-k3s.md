# GPU Worker Node

## Why

Ollama and future local AI/TTS workloads need a CUDA-capable GPU. The GPU host at `192.168.0.69` already has an NVIDIA 6 GB card and was previously running Ollama as a standalone systemd service, exposed through the cluster only as an external proxy (static `Endpoints` pointing at `192.168.0.69:11434`). Joining that host to the cluster as a third worker node lets Flux manage Ollama (and future TTS services) with the same GitOps workflow as everything else, while pinning GPU-bound pods to the only node with a GPU.

## Architecture

Three-node k3s cluster:

| Node | Role | Address | Services |
|------|------|---------|---------|
| `k3s` (Debian 12) | control-plane + worker | 192.168.0.251 | Traefik, Flux, Gatus, Homepage, Authentik, monitoring, etc. |
| `k3s-nas` (NixOS bare-metal NAS host, see [nas-k3s.md](nas-k3s.md)) | worker | 192.168.0.128 (static) | Sonarr, Radarr, Bazarr, Transmission, Immich |
| `ryzen` (NixOS host with NVIDIA GPU, rebuilt from Ubuntu 2026-07-30) | worker | 192.168.0.69 | Ollama, Whisper |

The GPU node carries a label and taint that pin GPU-dependent services to it:

```
label: node-role.kubernetes.io/gpu=true
taint: node-role.kubernetes.io/gpu=true:NoSchedule
```

Services not in the table above continue to run on the main or NAS node and are unaffected.

## Access

Traefik runs on the main node and handles all ingress. k3s CNI (Flannel) routes cross-node traffic transparently. Ollama and Whisper have no external Ingress — they are accessed in-cluster via Service DNS (`http://ollama:11434`, `http://whisper:9000`). Open WebUI at `https://chat.home.bstjohn.net` is the human-facing entrypoint for AI chat.

## Services on the GPU Node

| Service | GPU | Local PVCs | Notes |
|---------|-----|------------|-------|
| Ollama | `nvidia.com/gpu: 1` | `ollama-models-pvc` (100Gi) | Models are host-local; 6 GB VRAM caps practical model size at ~7B Q4 |
| Whisper | `nvidia.com/gpu: 1` | `whisper-models-pvc` (10Gi) | faster-whisper backend; int8 small model ~500 MiB VRAM; shares card with Ollama |
| (future) TTS | `nvidia.com/gpu: 1` | TBD | Piper, Coqui, etc. — scheduled to the same node |

The 6 GB card is shared cooperatively by the GPU pods. The nvidia-device-plugin is configured with **time-slicing** (`replicas: 2` for `nvidia.com/gpu`) so the single physical GPU is advertised as 2 allocatable units, letting both Ollama and Whisper schedule on the node at the same time. Time-slicing only affects scheduling — the GPU contexts are interleaved at runtime and VRAM is shared, so CUDA OOM is still possible if both workloads keep large models warm simultaneously. When Ollama loads a model it holds VRAM for `OLLAMA_KEEP_ALIVE` (30 min); Whisper's int8 small model is ~500 MiB which fits comfortably alongside a 7B Q4 Ollama model on the 6 GB card. Future TTS services should expect occasional contention and fall back to CPU.

## Setting Up the Worker Node

> **Deployment order**: Run the script first, then merge the PR.
> The node must be joined and labeled before Flux deploys Ollama — otherwise the pod stays `Pending` indefinitely waiting for a GPU node.
>
> 1. Run `setup-gpu-worker.sh` on the GPU host (joins the node as a k3s agent)
> 2. Apply the GPU label from the main node: `kubectl label node ryzen node-role.kubernetes.io/gpu=true`
> 3. Verify the node is `Ready` with the label and taint
> 4. Merge this PR — Flux deploys the device plugin and Ollama

### Prerequisites

- GPU host at `192.168.0.69`. **`setup-gpu-worker.sh` is Debian/Ubuntu-only** — it installs `nvidia-container-toolkit` from NVIDIA's apt repo (step 2 below). `ryzen` was reinstalled onto NixOS 26.11 on 2026-07-30 and is now provisioned from `St-John-Software/nixos-config`, not from this script. The script is retained for a from-scratch Debian/Ubuntu GPU worker; do not run it against `ryzen`.
- NVIDIA driver installed — verify with `nvidia-smi`. Driver installs typically require a reboot; do that before running the setup script.
- Existing systemd Ollama service stopped and disabled (otherwise port 11434 and the GPU will be held by the old process):
  ```bash
  sudo systemctl stop ollama && sudo systemctl disable ollama
  ```
- Back up existing models so you do not have to re-download them:
  ```bash
  sudo cp -a /usr/share/ollama/.ollama/models /tmp/ollama-models-backup/
  ```
  (If you installed Ollama as a user rather than via the system service, the models live under `~/.ollama/models`.)
- Node join token from the main node:
  ```bash
  sudo cat /var/lib/rancher/k3s/server/node-token
  ```

### Installation

Run on the GPU host as root:

```bash
sudo ./scripts/setup-gpu-worker.sh https://192.168.0.251:6443 "K10xxxx::server:xxxx" "v1.34.3+k3s1"
```

The k3s version must match the server. Get it from the main node first:

```bash
k3s --version
# Example output: k3s version v1.31.4+k3s1 (...)
```

The script:
1. Verifies `nvidia-smi` works (does not install the driver — that is a separate, reboot-inducing step)
2. Installs `nvidia-container-toolkit` from NVIDIA's apt repo
3. Installs k3s in agent mode, joining the existing cluster
4. Sets the `node-role.kubernetes.io/gpu=true:NoSchedule` taint at install time
5. Verifies the agent service is running

> **Order matters**: `nvidia-container-toolkit` must be installed *before* k3s. k3s detects `nvidia-container-runtime` on `$PATH` at install time and auto-configures containerd. The script enforces this order.

> **Note**: The `node-role.kubernetes.io/gpu=true` label must be applied separately from the control plane. Kubernetes 1.34+ blocks kubelet from self-applying labels in the `kubernetes.io` namespace. After the node joins, run on the main node:
> ```bash
> kubectl label node ryzen node-role.kubernetes.io/gpu=true
> ```

### Verifying the Node Joined

From the main node:

```bash
kubectl get nodes -o wide
kubectl describe node ryzen
```

The GPU node should appear as `Ready` with the `node-role.kubernetes.io/gpu=true` label and the matching taint.

## NVIDIA Device Plugin

k3s does not auto-mount NVIDIA devices into pods. The cluster runs the upstream [NVIDIA Kubernetes device plugin](https://github.com/NVIDIA/k8s-device-plugin) as a DaemonSet (managed by Flux in `apps/nvidia-device-plugin/`). The plugin:

- Registers `nvidia.com/gpu` as a schedulable resource on the GPU node
- Mounts NVIDIA devices and libraries into pods that request the resource

The accompanying `RuntimeClass` named `nvidia` (in `apps/nvidia-device-plugin/runtimeclass.yaml`) tells containerd to use the nvidia-container-runtime when a pod sets `runtimeClassName: nvidia`.

**Helm chart**: `https://nvidia.github.io/k8s-device-plugin` (HelmRepository in `clusters/my-cluster/infrastructure/nvidia-device-plugin/source.yaml`).

**Non-obvious Helm values** (`apps/nvidia-device-plugin/release.yaml`):

- **`runtimeClassName: nvidia`** — The plugin pod itself runs under the nvidia runtime. This injects `libnvidia-ml` and `/dev/nvidia*` into the container so the plugin can enumerate GPUs via NVML. Without this, the plugin crashloops with `Incompatible strategy detected auto` / `failed to construct resource managers`. There is no chicken-and-egg: RuntimeClass usability requires containerd to have the runtime registered (handled by `setup-gpu-worker.sh`), not `nvidia.com/gpu` to already be advertised.

- **`affinity: {}`** — Overrides the chart's default `nodeAffinity`, which requires Node Feature Discovery (NFD) labels like `feature.node.kubernetes.io/pci-10de.present` and `nvidia.com/gpu.present`. This cluster doesn't run NFD/GFD. Clearing the affinity lets the simpler `nodeSelector`/toleration approach work.

- **No `deviceIDStrategy` override (leave it unset → chart default `uuid`)** — deliberate. `ryzen` runs `nvidia-container-runtime` in CDI mode (`mode = "cdi"` in `/etc/nvidia-container-runtime/config.toml`), and the CDI spec at `/run/cdi/nvidia-container-toolkit.json` is regenerated on every boot and every `nixos-rebuild switch` by a generator that hardcodes `nvidia-ctk cdi generate --device-name-strategy uuid`. Switching the plugin to `deviceIDStrategy: index` would inject `NVIDIA_VISIBLE_DEVICES=0`, which has no matching entry in that host's CDI spec — every GPU pod would fail OCI create with `unresolvable CDI devices nvidia.com/gpu=0`. This surfaced as a red herring during the 2026-07-30 `ryzen` NixOS rebuild (issue #731): both Ollama and Whisper briefly CrashLoopBackOff'd while `/run/cdi/nvidia-container-toolkit.json` held a stale spec mid-rebuild, and `deviceIDStrategy: index` was drafted as a fix before the pods self-resolved once the CDI generator re-ran — do not apply that fix if the crashloop recurs; it would break both GPU services rather than help.

After the plugin is Ready, verify GPU capacity is exposed. With time-slicing (`replicas: 2`) configured in `apps/nvidia-device-plugin/release.yaml`, the single physical GPU is advertised as 2 allocatable units:

```bash
kubectl describe node ryzen | grep nvidia.com/gpu
# Capacity:
#   nvidia.com/gpu:  2
# Allocatable:
#   nvidia.com/gpu:  2
```

GPU pods then request the resource and specify the runtime class:

```yaml
spec:
  runtimeClassName: nvidia
  containers:
    - name: ollama
      resources:
        limits:
          nvidia.com/gpu: 1
```

## Migrating Ollama Models

The pre-existing systemd Ollama kept models at `/usr/share/ollama/.ollama/models` (or `~/.ollama/models` for a user-install). After the PR merges, Flux creates a fresh `ollama-models-pvc` PVC on the GPU node — empty. Without the migration step below, every model gets re-downloaded on first use.

```bash
# 1. On the GPU box (before joining), back the models up outside the k3s storage dir:
sudo systemctl stop ollama && sudo systemctl disable ollama
sudo cp -a /usr/share/ollama/.ollama/models /tmp/ollama-models-backup/

# 2. Join the node + merge the PR (Flux creates the PVC and the Deployment).

# 3. Scale the deployment to 0 so the volume is unmounted:
kubectl scale deployment ollama --replicas=0

# 4. Find the local-path hostPath directory for the PVC. local-path names the
#    directory <volume-name>_<namespace>_<pvc-name> under /var/lib/rancher/k3s/storage:
PV=$(kubectl get pvc ollama-models-pvc -o jsonpath='{.spec.volumeName}')
# SSH to the GPU host and copy:
sudo mkdir -p /var/lib/rancher/k3s/storage/${PV}_default_ollama-models-pvc/models
sudo cp -a /tmp/ollama-models-backup/. /var/lib/rancher/k3s/storage/${PV}_default_ollama-models-pvc/models/

# 5. Scale back up:
kubectl scale deployment ollama --replicas=1

# 6. Verify models are available (in-cluster — no external ingress):
kubectl exec -it deployment/ollama -- curl -s http://localhost:11434/api/tags | head -c 500
```

> **Confirm the local-path directory naming** by inspecting an existing local-path PVC directory on the GPU node before copying — the provisioner uses `<volume-name>_<namespace>_<pvc-name>` but the format can differ across provisioner versions.

## Offline Behaviour

When the GPU host shuts down:

1. k3s agent disconnects — node transitions to `NotReady`
2. After the default pod eviction timeout (~5 minutes), the Ollama pod is evicted
3. Evicted pods cannot reschedule elsewhere (the `gpu` taint and matching nodeSelector pin them)
4. Open WebUI (`chat.home.bstjohn.net`) will fail to reach Ollama until the pod is back

When the GPU host comes back online:

1. k3s agent reconnects, node returns to `Ready`
2. The nvidia-device-plugin pod starts, registers `nvidia.com/gpu`
3. Ollama is scheduled, mounts its PVC, loads models from local-path on first request

Ollama is intentionally **not** added to Flux health checks (`clusters/my-cluster/apps-kustomization.yaml`). Health checks on a node that is expected to be offline sometimes produce noisy Slack alerts — matches the pattern used for Immich.

## PVC Expansion on the GPU Worker

The `local-path` provisioner on the GPU worker node (`ryzen`) **does not support online volume expansion**. Resizing a local-path PVC requires a manual backup-delete-recreate procedure, the same as on `k3s-nas`.

**Procedure** (for any `local-path` PVC bound to `ryzen`):

1. Find the hostPath directory for the PVC:
   ```bash
   kubectl get pvc <pvc-name> -n default -o jsonpath='{.spec.volumeName}'
   # Data lives at /var/lib/rancher/k3s/storage/<volume-name>_default_<pvc-name>/ on ryzen
   ```
2. Scale down the workload to zero replicas.
3. Back up the data directory from the node (SSH to the GPU host):
   ```bash
   cp -a /var/lib/rancher/k3s/storage/<volume-name>_default_<pvc-name>/ /tmp/<service>-data-backup/
   ```
4. Delete the existing PVC: `kubectl delete pvc <pvc-name> -n default`
5. Update the PVC manifest to the new size and merge the PR so Flux applies it.
6. Get the new volume name and restore from backup:
   ```bash
   kubectl get pvc <pvc-name> -n default -o jsonpath='{.spec.volumeName}'
   cp -a /tmp/<service>-data-backup/. /var/lib/rancher/k3s/storage/<new-volume-name>_default_<pvc-name>/
   ```
7. Scale the workload back up and verify.

**Critical**: Complete the backup (step 3) before deleting the PVC. The provisioner removes the hostPath directory when the PVC is deleted.

## Resource Requirements

Ollama's resource needs depend on the model(s) loaded into VRAM. The 6 GB card caps practical model size. Typical starting point:

| Service | CPU limit | Memory limit | VRAM |
|---------|----------|--------------|------|
| Ollama (idle, no model loaded) | 4000m | 8 GiB | ~100 MiB |
| Ollama (7B Q4 model loaded) | 4000m | 8 GiB | ~4.5 GiB |

Host memory on the GPU box should comfortably exceed 8 GiB to leave room for the k3s agent (~300 MiB), containerd, and NVIDIA driver overhead. Disk: 100 Gi for the model PVC is generous for ~5–10 small/mid models; local-path does not enforce the PVC request, so the real limit is the root filesystem capacity.

First-request latency after pod start is 10–30 s while the model is loaded into VRAM. The deployment's `startupProbe` allows up to 2.5 minutes for this (`failureThreshold: 30`, `periodSeconds: 5`).

## k3s Version Sync

The agent must run the same k3s version as the server. Check the current server version:

```bash
k3s --version
```

When upgrading the server, upgrade the agent promptly:

```bash
# On the GPU host, re-run the install script with the target version — it upgrades in place.
sudo ./scripts/setup-gpu-worker.sh https://192.168.0.251:6443 "<TOKEN>" "<K3S_VERSION>"
```

## Troubleshooting

- **`nvidia.com/gpu` not on node Capacity**: the nvidia-device-plugin pod has not registered. Check `kubectl logs -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin`. Common causes: `nvidia-container-toolkit` was not installed before k3s, or the driver is broken on the host (re-run `nvidia-smi`).
- **Pod stuck in `Pending` with "no nodes available"**: the GPU node-role label is missing. `kubectl label node ryzen node-role.kubernetes.io/gpu=true`.
- **`CreateContainerError: runtime "nvidia" not registered`**: k3s was installed before `nvidia-container-toolkit`. Re-run the setup script — it reinstalls k3s in place, which regenerates the containerd config template and picks up the runtime.
- **Ollama loads but requests error `CUDA out of memory`**: the model does not fit in 6 GB VRAM at full precision. Use a smaller quantization or a smaller model.
- **`ollama`/`whisper` pods stuck in phase `Failed` with `status.reason: UnexpectedAdmissionError` after `ryzen` reboots** (issues #713/#714, closed 2026-08-05 as one-off cleanup, **not** structurally fixed): on every `ryzen` boot, kubelet restores `nvidia.com/gpu` capacity from its device-manager checkpoint and re-admits the pods already assigned to the node *before* the nvidia-device-plugin re-registers healthy devices. Admission fails with `Pod was rejected: Allocate failed due to no healthy devices present`. The Deployment immediately schedules a working replacement — the service self-heals within seconds — but the rejected pod is left behind in phase `Failed` forever; nothing in this repo garbage-collects it. Each `ryzen` reboot adds one fresh tombstone per GPU workload, and each poll of the cluster's pod-failure monitoring re-reports every tombstone still present. **Filter on `.status.reason == "UnexpectedAdmissionError"`, never on the `kubectl get pods` STATUS column** — a tombstone can show `ContainerStatusUnknown` in that column while `.status.reason` is still `UnexpectedAdmissionError`. To clear them by hand: `kubectl delete pod -n default $(kubectl get pods -n default --field-selector status.phase=Failed -o jsonpath='{range .items[?(@.status.reason=="UnexpectedAdmissionError")]}{.metadata.name}{" "}{end}')`. A proposed automated reaper CronJob (`apps/admission-error-reaper/`) was designed but never merged — if this recurs frequently enough to be worth automating, that design is the starting point, not a fresh one.
