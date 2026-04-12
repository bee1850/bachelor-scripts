#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/generic.sh"

start_message

install_dependencies

install_k3s

install_helm

setup_kubeconfig
install_hey
