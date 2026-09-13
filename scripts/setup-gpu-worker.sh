#!/usr/bin/env bash
# setup-gpu-worker.sh
# Run this on the Ubuntu host with the NVIDIA GPU (previously the standalone
# Ollama box, 192.168.0.69) to install k3s agent and join it to the existing
# cluster as a GPU-enabled worker node.
#
# Usage:
#   ./setup-gpu-worker.sh <K3S_URL> <K3S_TOKEN> [K3S_VERSION]
#
# Where:
#   K3S_URL     - URL of the k3s API server, e.g. https://192.168.0.251:6443
#   K3S_TOKEN   - Node join token from /var/lib/rancher/k3s/server/node-token on the main node
#   K3S_VERSION - (optional) k3s version to install, e.g. v1.31.4+k3s1
#                 MUST match the server version — check with: k3s --version on the main node
#                 If omitted, the latest release is installed (may cause version mismatch)
#
# Example:
#   sudo ./setup-gpu-worker.sh https://192.168.0.251:6443 "K10::server:xxxx" v1.31.4+k3s1
#
# Prerequisites (verify BEFORE running):
#   - NVIDIA driver installed (nvidia-smi must work) — driver installs often
#     require a reboot; do that separately, not from this script.
#   - Existing systemd ollama.service stopped and disabled:
#       sudo systemctl stop ollama && sudo systemctl disable ollama
#   - Existing Ollama models backed up (optional but saves re-downloading):
#       sudo cp -a /usr/share/ollama/.ollama/models /tmp/ollama-models-backup/

set -euo pipefail

# --- Argument handling ---

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <K3S_URL> <K3S_TOKEN> [K3S_VERSION]"
  echo
  echo "Get the token from the main node:"
  echo "  sudo cat /var/lib/rancher/k3s/server/node-token"
  echo
  echo "Get the server version from the main node:"
  echo "  k3s --version"
  exit 1
fi

K3S_URL="$1"
K3S_TOKEN="$2"
K3S_VERSION="${3:-}"

if [[ $EUID -ne 0 ]]; then
  echo "Error: this script must be run as root (use sudo)"
  exit 1
fi

echo "==> Setting up GPU host as k3s worker node"
echo "    Server: ${K3S_URL}"
echo

# --- Verify NVIDIA driver ---

echo "==> Verifying NVIDIA driver is installed"
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "Error: nvidia-smi not found. Install the NVIDIA driver first."
  echo "  On Ubuntu: sudo apt-get install -y nvidia-driver-<version>"
  echo "  Driver installs typically require a reboot — install and reboot before re-running this script."
  exit 1
fi

if ! nvidia-smi >/dev/null 2>&1; then
  echo "Error: nvidia-smi failed. The driver may not be loaded — try rebooting."
  exit 1
fi

echo "    NVIDIA driver OK:"
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | sed 's/^/      /'

# --- Install nvidia-container-toolkit (MUST be before k3s) ---
#
# k3s detects nvidia-container-runtime at install time and auto-generates the
# containerd config template. If k3s is installed first, the runtime is not
# registered and GPU pods will fail to start.

echo
echo "==> Installing NVIDIA container toolkit"

if ! command -v nvidia-ctk >/dev/null 2>&1; then
  echo "    Adding NVIDIA container toolkit apt repo"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list

  apt-get update
  apt-get install -y nvidia-container-toolkit
  echo "    nvidia-container-toolkit installed"
else
  echo "    nvidia-container-toolkit already installed"
fi

# --- Install k3s agent ---

echo
echo "==> Installing k3s agent"
echo "    Node taint: node-role.kubernetes.io/gpu=true:NoSchedule"
echo "    Note: node-role label must be applied from the control plane after joining (kubelet"
echo "          in k8s 1.34+ rejects self-applied labels in the kubernetes.io namespace)"
if [[ -n "${K3S_VERSION}" ]]; then
  echo "    k3s version: ${K3S_VERSION}"
else
  echo "    k3s version: latest (WARNING: ensure this matches the server version)"
fi

INSTALL_K3S_EXEC="agent --node-taint node-role.kubernetes.io/gpu=true:NoSchedule"
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC}" INSTALL_K3S_VERSION="${K3S_VERSION}" K3S_URL="${K3S_URL}" K3S_TOKEN="${K3S_TOKEN}" sh -s -

echo "    k3s agent installed and started"

# --- Verify ---

echo
echo "==> Waiting for service to start..."
sleep 10

if systemctl is-active --quiet k3s-agent; then
  echo "    k3s-agent service is running"
  echo "    Note: this confirms the service started, not that the node registered with the cluster."
  echo "    Verify cluster registration with: kubectl get nodes (run on the main k3s node)"
else
  echo "Error: k3s-agent service failed to start — check: journalctl -u k3s-agent -n 50"
  exit 1
fi

echo
echo "==> Setup complete!"
echo
echo "Next steps (run on the main k3s node at 192.168.0.251):"
echo
echo "  1. Apply the gpu node-role label (cannot be set at install time in k8s 1.34+):"
echo "     kubectl label node $(hostname) node-role.kubernetes.io/gpu=true"
echo
echo "  2. Verify this node appears as Ready:"
echo "     kubectl get nodes -o wide"
echo
echo "  3. Confirm labels and taints:"
echo "     kubectl describe node $(hostname)"
echo
echo "  4. Merge the PR so Flux installs the NVIDIA device plugin and the Ollama Deployment."
echo "     Once the device plugin DaemonSet is Ready, confirm GPU capacity is exposed:"
echo "       kubectl describe node $(hostname) | grep nvidia.com/gpu"
echo
echo "  5. Migrate existing Ollama models into the new PVC:"
echo "     a. kubectl scale deployment ollama --replicas=0"
echo "     b. PV=\$(kubectl get pvc ollama-models-pvc -o jsonpath='{.spec.volumeName}')"
echo "     c. On this host, copy the model backup into the PVC directory:"
echo "        sudo mkdir -p /var/lib/rancher/k3s/storage/\${PV}_default_ollama-models-pvc/models"
echo "        sudo cp -a /tmp/ollama-models-backup/. /var/lib/rancher/k3s/storage/\${PV}_default_ollama-models-pvc/models/"
echo "     d. kubectl scale deployment ollama --replicas=1"
echo "     e. curl -s https://ollama.home.bstjohn.net/api/tags | jq"
echo
echo "  6. Re-running this script is safe — the k3s installer upgrades in place when"
echo "     INSTALL_K3S_VERSION changes."
echo
echo "See docs/gpu-k3s.md for full documentation."
