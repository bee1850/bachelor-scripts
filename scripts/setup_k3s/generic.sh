#!/bin/bash
set -e

# Helper/shared functions for K3s / gVisor setup scripts
# Located next to the caller scripts; sourced with
# . "$(dirname "${BASH_SOURCE[0]}")/generic.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "$@"; }

start_message() {
	log "Starting setup on Bare Metal..."
}

install_dependencies() {
	log "Installing dependencies..."
	sudo apt-get update && sudo apt-get install -y \
		apt-transport-https \
		ca-certificates \
		curl \
		gnupg \
		build-essential \
		libssl-dev \
		git \
		zlib1g-dev \
		postgresql-client \
		postgresql-contrib \
		jq
}

setup_kubeconfig() {
	log "Setting up local kubeconfig..."
	mkdir -p ~/.kube
	# copy only if k3s kubeconfig exists
	if [ -f /etc/rancher/k3s/k3s.yaml ]; then
		sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
		sudo chown "$(id -u):$(id -g)" ~/.kube/config
	else
		log "/etc/rancher/k3s/k3s.yaml not found; skipping kubeconfig copy"
	fi
}

install_helm() {
    curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
}

install_hey() {
	if command -v hey >/dev/null 2>&1; then
		log "'hey' already installed, skipping."
		return
	fi
	log "Installing 'hey' for performance testing..."
	wget -q https://storage.googleapis.com/hey-releases/hey_linux_amd64 -O /tmp/hey_linux_amd64
	sudo mv /tmp/hey_linux_amd64 /usr/local/bin/hey
	sudo chmod +x /usr/local/bin/hey
}

install_k3s() {
    # Install K3s (kubelet systemd cgroup driver)
    log "Installing K3s with explicit systemd cgroup driver..."
    curl -sfL https://get.k3s.io | sh -s - --kubelet-arg="cgroup-driver=systemd"

    log "Waiting for K3s to initialize..."
    sleep 10
}