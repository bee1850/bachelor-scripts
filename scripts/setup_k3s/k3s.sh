#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status

# Source generic helpers (relative to this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/generic.sh"

start_message

install_dependencies

install_k3s

install_helm

# Shared post-install steps
setup_kubeconfig
install_hey
