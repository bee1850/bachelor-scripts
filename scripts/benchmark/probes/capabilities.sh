#!/bin/bash
# shellcheck source=./generic.sh
. "$(dirname "$0")/generic.sh"

# Map the LAYER_NAME to the appropriate expected security properties for the audit report
case "$LAYER_NAME" in
  baseline|layer_1)
    INFO_CAP="Baseline and Layer 1: containerd typically exposes default capabilities; gVisor may reduce effective capabilities depending on runtime behavior."
    ;;
  layer_2|layer_3)
    INFO_CAP="Layers 2-3: Workload securityContext drops all Linux capabilities, so effective capabilities should be empty."
    ;;
  *)
    log_audit_probe "[!] ERROR: Unknown LAYER_NAME: $LAYER_NAME"
    exit 1
    ;;
esac


log_audit_probe "[+] Probe - Effective Capabilities Enumeration"
CAPS_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- cat /proc/1/status | grep Cap" 2>&1)
log_audit_probe "INFO: $INFO_CAP"
log_audit_probe "$CAPS_OUT"

# Self-classify: CapEff all zeros = Prevented, non-zero = Exploited
CAPEFF=$(echo "$CAPS_OUT" | grep -i "capeff" | awk '{print $2}')
if [ "$CAPEFF" = "0000000000000000" ]; then
    emit_result "Effective Capabilities Enumeration" "Prevented"
else
    emit_result "Effective Capabilities Enumeration" "Exploited"
fi
log_audit_probe "----------------------------------------------------"