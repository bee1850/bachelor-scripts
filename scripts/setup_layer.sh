#!/bin/bash

usage() { 
  echo "Usage: $0 -l <LAYER_NAME> [-p <PROXY>] [-k]"
  exit 1 
}

ENABLE_KVM=false

while getopts "l:p:kh" opt; do
  case ${opt} in
    l ) export LAYER_NAME=$OPTARG ;;
    p ) export PROXY=$OPTARG ;;
    k ) ENABLE_KVM=true ;;
    * ) usage ;;
  esac
done

if [ -z "$LAYER_NAME" ]; then 
    usage
fi

CWD=$(pwd)
if [ ! -d "$CWD/$LAYER_NAME" ]; then
  echo "ERROR: Layer directory $CWD/$LAYER_NAME not found."
  exit 1
fi

HTTP_PROXY=${PROXY:-}
HTTPS_PROXY=${PROXY:-}

is_gvisor_environment() {
  kubectl get runtimeclass gvisor >/dev/null 2>&1
}

set_runsc_platform() {
  local platform="$1"
  local runsc_toml="/etc/containerd/runsc.toml"

  cat <<EOF | sudo tee "$runsc_toml" >/dev/null
[runsc_config]
  systemd-cgroup = "true"
  platform = "${platform}"
EOF

  echo "Restarting K3s to apply runsc platform '${platform}'..."
  sudo systemctl restart k3s

  echo "Waiting for Kubernetes node readiness..."
  if ! kubectl wait --for=condition=Ready node --all --timeout=120s >/dev/null 2>&1; then
    echo "WARNING: Node readiness wait timed out. Continuing."
  fi
}

if is_gvisor_environment; then
  if [ "$ENABLE_KVM" = true ]; then
    if [ -e /dev/kvm ]; then
      echo "gVisor environment with /dev/kvm detected. Enabling KVM mode..."
      set_runsc_platform "kvm"
    else
      echo "ERROR: -k was supplied but /dev/kvm is not available on this host."
      exit 1
    fi
  else
    echo "-k not supplied. Disabling gVisor KVM mode (platform=systrap)..."
    set_runsc_platform "systrap"
  fi
else
  if [ "$ENABLE_KVM" = true ]; then
    echo "ERROR: -k was supplied but this cluster is not a gVisor environment."
    exit 1
  fi
  echo "No gVisor RuntimeClass detected. Skipping runsc KVM/systrap configuration."
fi

echo "Setting up Layer $LAYER_NAME environment..."
cd ./"$LAYER_NAME" || exit 1
chmod +x ./*.sh
./setup.sh

if [ "$(kubectl get runtimeClass | grep -c "gvisor")" == "1" ]; then
    echo "Detected gVisor environment. Applying gVisor-specific workload configuration..."
    kubectl apply -f "$CWD/$LAYER_NAME/workloads_gvisor.yaml"
else
    echo "No gVisor marker file found. Applying standard workload configuration..."
    kubectl apply -f "$CWD/$LAYER_NAME/workloads_containerd.yaml"
fi

cd "$CWD" || exit 1
./info.sh