#!/bin/bash

# Default variables
export TARGET_USER="root"
export DURATION=120
export PROXY=""
export ITERATION=1
RUN_BENCHMARKS=false
RUN_AUDITS=false

usage() { 
  echo "Usage: $0 -t <TARGET_IP> -l <LAYER_NAME> -r <RUNTIME> [-p <PROXY>] [-d <DURATION>] [-i <ITERATION>] [-b] [-a]"
  echo "  -b  Run performance benchmarks."
  echo "  -a  Run security audit."
  echo "  (If neither -b nor -a is specified, both are run.)"
  exit 1 
}

while getopts "t:l:r:d:p:i:bah" opt; do
  case ${opt} in
    t ) export TARGET_IP=$OPTARG ;;
    l ) export LAYER_NAME=$OPTARG ;;
    r ) export RUNTIME=$OPTARG ;;
    d ) export DURATION=$OPTARG ;;
    p ) export PROXY=$OPTARG ;;
    i ) export ITERATION=$OPTARG ;;
    b ) RUN_BENCHMARKS=true ;;
    a ) RUN_AUDITS=true ;;
    * ) usage ;;
  esac
done

if [ -z "$TARGET_IP" ] || [ -z "$LAYER_NAME" ] || [ -z "$RUNTIME" ]; then 
    usage
fi

# Default: run both if neither flag was specified
if [ "$RUN_BENCHMARKS" = false ] && [ "$RUN_AUDITS" = false ]; then
  RUN_BENCHMARKS=true
  RUN_AUDITS=true
fi

export HTTPS_PROXY="$PROXY" 
export HTTP_PROXY="$PROXY"

export RESULTS_DIR="/root/results/${LAYER_NAME}/${RUNTIME}"
mkdir -p "$RESULTS_DIR"

CLEANUP_DONE=false

run_remote_cleanup() {
  if [ "$CLEANUP_DONE" = true ]; then
    return
  fi
  echo "[*] Running target cleanup at end of benchmark run..."
  ssh -q "$TARGET_USER@$TARGET_IP" "cd ~ && ./cleanup.sh" || echo "[!] Warning: cleanup failed on target node."
  CLEANUP_DONE=true
}

trap 'run_remote_cleanup' EXIT

echo "[*] Configuration:"
echo "    Target IP: $TARGET_IP"
echo "    Runtime: $RUNTIME"
echo "    Results Directory: $RESULTS_DIR"

# Source the external modules
source ./setup.sh

if [ "$RUN_BENCHMARKS" = true ]; then
  source ./run.sh
else
  echo "[*] Skipping performance benchmarks."
fi

if [ "$RUN_AUDITS" = true ]; then
  source ./audit.sh
else
  echo "[*] Skipping security audit."
fi

echo "[*] All tasks complete."