#!/bin/bash
# shellcheck source=./generic.sh
. "$(dirname "$0")/generic.sh"

case "$LAYER_NAME" in
  baseline|layer_1)
    INFO_CDM="Baseline: For standard containerd, mounting might be prevented unless the pod is privileged, but cgroup information leaks can occur. gVisor fully sandboxes the mount space."
    ;;
  layer_2|layer_3)
    INFO_CDM="Layers 2-3: Pod Security labels and workload hardening reduce mount-related abuse by removing privileges and blocking unsafe pod specs."
    ;;
  *)
    log_audit_probe "[!] ERROR: Unknown LAYER_NAME: $LAYER_NAME"
    exit 1
    ;;
esac

log_audit_probe "[+] Probe - Unauthorized cGroup & Device Mounting"
log_audit_probe "INFO: $INFO_CDM"

# 1. Attempt to mount cgroup (CVE-2022-0492)
CGROUP_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- sh -c 'mkdir -p /tmp/cgroup && mount -t cgroup -o memory cgroup /tmp/cgroup 2>&1'")
log_audit_probe "cGroup Mount Result: $CGROUP_OUT"

# 2. Attempt to mount host block devices (e.g., /dev/nvme0n1p2)

DEVICE_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- sh -c 'mkdir -p /tmp/host_disk && mount /dev/nvme0n1p2 /tmp/host_disk 2>&1 || mount /dev/nvme0n1p1 /tmp/host_disk 2>&1'")
log_audit_probe "Block Device Mount Result: $DEVICE_OUT"

# Self-classify
ALL_CG="$CGROUP_OUT $DEVICE_OUT"
if echo "$ALL_CG" | grep -qi "permission denied\|operation not permitted\|not permitted"; then
    emit_result "Unauthorized cGroup & Device Mounting" "Prevented"
else
    emit_result "Unauthorized cGroup & Device Mounting" "Exploited"
fi
log_audit_probe "----------------------------------------------------"
