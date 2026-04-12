#!/bin/bash
# shellcheck source=./generic.sh
. "$(dirname "$0")/generic.sh"

# Map the LAYER_NAME to the appropriate expected security properties for the audit report
case "$LAYER_NAME" in
  baseline|layer_1)
    INFO_PSL="Baseline and Layer 1: containerd exposes real /proc/kallsyms, /proc/sched_debug, /sys/kernel/security/lsm, /sys/firmware/dmi/tables. gVisor Sentry virtualizes procfs and returns empty or restricted results."
    ;;
  layer_2)
    INFO_PSL="Layer 2: containerd still exposes some /proc entries (e.g., /proc/net/dev). gVisor virtualizes procfs entirely, preventing leakage."
    ;;
  layer_3)
    INFO_PSL="Layer 3: Same as L2 but Falco may alert on sensitive procfs/sysfs reads."
    ;;
  *)
    log_audit_probe "[!] ERROR: Unknown LAYER_NAME: $LAYER_NAME"
    exit 1
    ;;
esac

log_audit_probe "[+] Probe - Sensitive Procfs/Sysfs Leakage"
log_audit_probe "INFO: $INFO_PSL"

# Test 1: Kernel symbol table
KALLSYMS_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- cat /proc/kallsyms 2>&1 | head -n 5")
if [ -z "$KALLSYMS_OUT" ] || echo "$KALLSYMS_OUT" | grep -qi "permission denied\|no such file\|operation not permitted"; then
    log_audit_probe "   /proc/kallsyms: BLOCKED"
else
    log_audit_probe "   /proc/kallsyms: READABLE (first 5 lines follow)"
    log_audit_probe "$KALLSYMS_OUT"
fi

# Test 2: Scheduler debug info
SCHED_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- cat /proc/sched_debug 2>&1 | head -n 5")
if [ -z "$SCHED_OUT" ] || echo "$SCHED_OUT" | grep -qi "permission denied\|no such file\|operation not permitted"; then
    log_audit_probe "   /proc/sched_debug: BLOCKED"
else
    log_audit_probe "   /proc/sched_debug: READABLE (first 5 lines follow)"
    log_audit_probe "$SCHED_OUT"
fi

# Test 3: LSM list
LSM_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- cat /sys/kernel/security/lsm 2>&1")
if [ -z "$LSM_OUT" ] || echo "$LSM_OUT" | grep -qi "permission denied\|no such file\|operation not permitted"; then
    log_audit_probe "   /sys/kernel/security/lsm: BLOCKED"
else
    log_audit_probe "   /sys/kernel/security/lsm: READABLE ($LSM_OUT)"
fi

# Test 4: Hardware fingerprinting via DMI tables
DMI_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- ls /sys/firmware/dmi/tables 2>&1")
if echo "$DMI_OUT" | grep -qi "permission denied\|no such file\|operation not permitted"; then
    log_audit_probe "   /sys/firmware/dmi/tables: BLOCKED"
else
    log_audit_probe "   /sys/firmware/dmi/tables: READABLE ($DMI_OUT)"
fi

# Test 5: /proc/net/dev (network topology)
PROCNET_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- cat /proc/net/dev 2>&1")
if [ -z "$PROCNET_OUT" ] || echo "$PROCNET_OUT" | grep -qi "permission denied\|no such file\|operation not permitted"; then
    log_audit_probe "   /proc/net/dev: BLOCKED"
else
    log_audit_probe "   /proc/net/dev: READABLE"
    log_audit_probe "$PROCNET_OUT"
fi

# Self-classify: count how many of the 5 paths were READABLE vs BLOCKED
READABLE_COUNT=0
[ -n "$KALLSYMS_OUT" ] && ! echo "$KALLSYMS_OUT" | grep -qi "permission denied\|no such file\|operation not permitted" && READABLE_COUNT=$((READABLE_COUNT+1))
[ -n "$SCHED_OUT" ] && ! echo "$SCHED_OUT" | grep -qi "permission denied\|no such file\|operation not permitted" && READABLE_COUNT=$((READABLE_COUNT+1))
[ -n "$LSM_OUT" ] && ! echo "$LSM_OUT" | grep -qi "permission denied\|no such file\|operation not permitted" && READABLE_COUNT=$((READABLE_COUNT+1))
! echo "$DMI_OUT" | grep -qi "permission denied\|no such file\|operation not permitted" && READABLE_COUNT=$((READABLE_COUNT+1))
[ -n "$PROCNET_OUT" ] && ! echo "$PROCNET_OUT" | grep -qi "permission denied\|no such file\|operation not permitted" && READABLE_COUNT=$((READABLE_COUNT+1))

if [ "$READABLE_COUNT" -eq 0 ]; then
    emit_result "Sensitive Procfs/Sysfs Leakage" "Prevented"
elif [ "$READABLE_COUNT" -le 2 ]; then
    emit_result "Sensitive Procfs/Sysfs Leakage" "Mitigated"
else
    emit_result "Sensitive Procfs/Sysfs Leakage" "Exploited"
fi
log_audit_probe "----------------------------------------------------"
