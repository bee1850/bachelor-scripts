#!/bin/bash
# shellcheck source=./generic.sh
. "$(dirname "$0")/generic.sh"

# Map the LAYER_NAME to the appropriate expected security properties for the audit report
case "$LAYER_NAME" in
  baseline)
    INFO_LM="Baseline: No Isolation full communication between Nginx and Postgres should be possible."
    ;;
  layer_1)
    INFO_LM="Layer 1: Only Inter-Tenant Lateral Movement should be possible."
    ;;
  layer_2)
    INFO_LM="Layer 2: Isolation through Capsule with Network Policies."
    ;;
  layer_3)
    INFO_LM="Layer 3: Isolation through Capsule/Tetragon. Exit Code will be 137."
    ;;
  *)
    log_audit_probe "[!] ERROR: Unknown LAYER_NAME: $LAYER_NAME"
    exit 1
    ;;
esac

log_audit_probe "[+] Probe - Intra-Tenant Lateral Movement A (Nginx -> Postgres)"
LATERAL_OUT_A=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- nc -zv -w 3 $POSTGRES_IP 5432" 2>&1)
log_audit_probe "INFO: $INFO_LM"
log_audit_probe "$LATERAL_OUT_A"

# Self-classify A
if echo "$LATERAL_OUT_A" | grep -qi "open\| succeeded"; then
    emit_result "Intra-Tenant Lateral Movement A (Nginx -> Postgres)" "Exploited"
elif echo "$LATERAL_OUT_A" | grep -qi "exit code 137"; then
    emit_result "Intra-Tenant Lateral Movement A (Nginx -> Postgres)" "Prevented"
elif echo "$LATERAL_OUT_A" | grep -qi "timed out\|refused\|not permitted\|exit code 1"; then
    emit_result "Intra-Tenant Lateral Movement A (Nginx -> Postgres)" "Prevented"
else
    emit_result "Intra-Tenant Lateral Movement A (Nginx -> Postgres)" "Unknown"
fi
log_audit_probe "----------------------------------------------------"
# --------------------------------------------------------------------------
log_audit_probe "[+] Probe - Intra-Tenant Lateral Movement B (Postgres -> Nginx)"
case "$LAYER_NAME" in
  baseline|layer_1)
    LATERAL_OUT_B=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_BACK $POSTGRES_POD -- wget -S -T 3 -O /dev/null http://$NGINX_IP:80" 2>&1)
    ;;
  layer_2|layer_3)
    LATERAL_OUT_B=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_BACK $POSTGRES_POD -- nc -zv -w 3 $NGINX_IP 8080" 2>&1)
    ;;
  *)
    echo "[!] ERROR: Unknown LAYER_NAME: $LAYER_NAME"
    exit 1
    ;;
esac
log_audit_probe "INFO: $INFO_LM"
log_audit_probe "$LATERAL_OUT_B"

# Self-classify B
if echo "$LATERAL_OUT_B" | grep -qi "200 ok\|open\| succeeded"; then
    emit_result "Intra-Tenant Lateral Movement B (Postgres -> Nginx)" "Exploited"
elif echo "$LATERAL_OUT_B" | grep -qi "timed out\|refused\|not permitted\|exit code 1\|exit code 137"; then
    emit_result "Intra-Tenant Lateral Movement B (Postgres -> Nginx)" "Prevented"
else
    emit_result "Intra-Tenant Lateral Movement B (Postgres -> Nginx)" "Unknown"
fi
log_audit_probe "----------------------------------------------------"

run_third_audit() {
    log_audit_probe "[+] Probe - Inter-Tenant Lateral Movement (Tenant-A Nginx -> Tenant-B Nginx)"
    case "$LAYER_NAME" in
      layer_1)
        TARGET_PORT=80
        ;;
      *)
        TARGET_PORT=8080
        ;;
    esac
    LATERAL_OUT_C=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- nc -zv -w 3 $NGINX_B_IP $TARGET_PORT" 2>&1)
    log_audit_probe "INFO: Inter Tenant Lateral Movement should be prevented through Network Policies and Capsule Namespace Isolation."
    log_audit_probe "$LATERAL_OUT_C"

    # Self-classify C
    if echo "$LATERAL_OUT_C" | grep -qi "open\| succeeded"; then
        emit_result "Inter-Tenant Lateral Movement (Tenant-A Nginx -> Tenant-B Nginx)" "Exploited"
    elif echo "$LATERAL_OUT_C" | grep -qi "timed out\|refused\|not permitted\|exit code 1\|exit code 137"; then
        emit_result "Inter-Tenant Lateral Movement (Tenant-A Nginx -> Tenant-B Nginx)" "Prevented"
    else
        emit_result "Inter-Tenant Lateral Movement (Tenant-A Nginx -> Tenant-B Nginx)" "Unknown"
    fi
    log_audit_probe "----------------------------------------------------"
}

case "$LAYER_NAME" in
  layer_1|layer_2|layer_3)
    run_third_audit
    ;;
  *)
    log_audit_probe "[!] Skipping Inter-Tenant Lateral Movement Probe for $LAYER_NAME as it's not applicable."
    ;;
esac