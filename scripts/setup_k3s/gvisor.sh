#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status

# Source generic helpers (relative to this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/generic.sh"

start_message

install_dependencies

# Install gVisor
echo "Installing gVisor from apt..."
curl -fsSL https://gvisor.dev/archive.key | sudo gpg --yes --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" | sudo tee /etc/apt/sources.list.d/gvisor.list > /dev/null

sudo apt-get update && sudo apt-get install -y runsc

install_k3s

install_helm

# Configure Containerd for K3s
echo "Configuring containerd template for gVisor..."
sudo mkdir -p /var/lib/rancher/k3s/agent/etc/containerd/

# Note: We intentionally omit SystemdCgroup=true here to prevent the silent parsing failure
cat <<EOF | sudo tee /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl
{{ template "base" . }}

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc.options]
  TypeUrl = "io.containerd.runsc.v1.options"
  ConfigPath = "/etc/containerd/runsc.toml"
EOF

# Configure gVisor Shim
echo "Configuring runsc shim for systemd..."
sudo mkdir -p /etc/containerd/

# Apply Changes
echo "Restarting K3s to apply containerd changes..."
sudo systemctl restart k3s

echo "Waiting for K3s to come back up..."
sleep 15

# Apply Kubernetes RuntimeClass
echo "Applying gVisor RuntimeClass..."
cat <<EOF | sudo k3s kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
EOF

# Shared post-install steps
setup_kubeconfig
install_hey
