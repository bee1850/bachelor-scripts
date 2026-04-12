#!/bin/bash
# shellcheck source=./generic.sh
. "$(dirname "$0")/generic.sh"

case "$LAYER_NAME" in
  baseline|layer_1)
    INFO_SI="Baseline and Layer 1: Default Seccomp (if any) might apply. Some namespaces operations or dmesg might be permitted."
    ;;
   layer_2|layer_3)
    INFO_SI="Layers 2/3: Strict Seccomp profiles and Pod Security Standards should block unshare, dmesg, and chroot."
    ;;
  *)
    log_audit_probe "[!] ERROR: Unknown LAYER_NAME: $LAYER_NAME"
    exit 1
    ;;
esac

log_audit_probe "[+] Probe - Privileged Syscall & Namespace Abuse"
log_audit_probe "INFO: $INFO_SI"

UNSHARE_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- unshare -U echo 'Unshare_Success'" 2>&1)
log_audit_probe "Unshare (Namespace Creation) Result: $UNSHARE_OUT"

DMESG_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- dmesg | head -n 2" 2>&1)
if [[ -z "$DMESG_OUT" ]]; then
    DMESG_OUT="No output / Permission denied"
fi
log_audit_probe "dmesg (Kernel Ring Buffer) Result: $DMESG_OUT"

CHROOT_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- chroot / /bin/true" 2>&1)
log_audit_probe "chroot Result: $CHROOT_OUT"

# Self-classify
ALL_SYSCALL="$UNSHARE_OUT $DMESG_OUT $CHROOT_OUT"
if echo "$UNSHARE_OUT" | grep -q "Unshare_Success"; then
    if echo "$ALL_SYSCALL" | grep -qi "starting gvisor\|gvisor"; then
        emit_result "Privileged Syscall & Namespace Abuse" "Mitigated"
    else
        emit_result "Privileged Syscall & Namespace Abuse" "Exploited"
    fi
elif echo "$ALL_SYSCALL" | grep -qi "permission denied\|operation not permitted\|exit code 1\|exit code 137"; then
    emit_result "Privileged Syscall & Namespace Abuse" "Prevented"
else
    emit_result "Privileged Syscall & Namespace Abuse" "Mitigated"
fi
log_audit_probe "----------------------------------------------------"
