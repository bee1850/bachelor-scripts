#!/bin/bash
# shellcheck source=./generic.sh
. "$(dirname "$0")/generic.sh"

# Map the LAYER_NAME to the appropriate expected security properties for the audit report
case "$LAYER_NAME" in
  baseline|layer_1|layer_2)
    INFO_KV="Baseline: For gVisor, this should show 4.4.0 or similar, not the host kernel version. containerD will show the host kernel version."
    ;;
  layer_3)
    INFO_KV="Layer 3: For gVisor, this should show 4.4.0 or similar, not the host kernel version. Tetragon should prevent the command from executing altough alternative kernel fingerprinting techniques may still be possible."
    ;;
  *)
    log_audit_probe "[!] ERROR: Unknown LAYER_NAME: $LAYER_NAME"
    exit 1
    ;;
esac

log_audit_probe "[+] Probe - Host Kernel Fingerprinting"
KERNEL_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- uname -r" 2>&1)
log_audit_probe "INFO: $INFO_KV"
log_audit_probe "Result: $KERNEL_OUT"

# Self-classify
if echo "$KERNEL_OUT" | grep -qi "command terminated with exit code 137\|Sigkill"; then
    emit_result "Host Kernel Fingerprinting" "Prevented"
elif echo "$KERNEL_OUT" | grep -q "4.4.0"; then
    emit_result "Host Kernel Fingerprinting" "Mitigated"
else
    emit_result "Host Kernel Fingerprinting" "Exploited"
fi
log_audit_probe "----------------------------------------------------"