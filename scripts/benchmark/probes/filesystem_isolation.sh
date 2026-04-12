#!/bin/bash
# shellcheck source=./generic.sh
. "$(dirname "$0")/generic.sh"

case "$LAYER_NAME" in
  baseline|layer_1)
    INFO_FS="Baseline and Layer 1: Root filesystem is likely writable."
    ;;
  layer_2|layer_3)
    INFO_FS="Layers 2-3: Root filesystem may still be writable unless readOnlyRootFilesystem is explicitly set in the workload securityContext."
    ;;
  *)
    log_audit_probe "[!] ERROR: Unknown LAYER_NAME: $LAYER_NAME"
    exit 1
    ;;
esac

log_audit_probe "[+] Probe - RootFS Immutability Check"
log_audit_probe "INFO: $INFO_FS"
WRITE_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- touch /bin/malicious_binary 2>&1")
log_audit_probe "Write to /bin Result: $WRITE_OUT"
ROOT_WRITE_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- touch /malicious_file 2>&1")
log_audit_probe "Write to / Result: $ROOT_WRITE_OUT"

# Self-classify: any write succeeds without error = Exploited
ALL_FS="$WRITE_OUT $ROOT_WRITE_OUT"
if echo "$ALL_FS" | grep -qi "permission denied\|read-only file system\|operation not permitted"; then
    emit_result "RootFS Immutability Check" "Prevented"
else
    emit_result "RootFS Immutability Check" "Exploited"
fi
log_audit_probe "----------------------------------------------------"
