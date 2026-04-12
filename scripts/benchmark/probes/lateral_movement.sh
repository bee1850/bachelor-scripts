#!/bin/bash
# shellcheck source=./generic.sh
. "$(dirname "$0")/generic.sh"

classify_result() {
    local output="$1"
    local probe_name="$2"

    if echo "$output" | grep -qiE "open|200 ok"; then
        emit_result "$probe_name" "Exploited"
        return
    fi

    if echo "$output" | grep -qiE "exit code 137|terminated by signal 9"; then
        emit_result "$probe_name" "Prevented"
        return
    fi

    if echo "$output" | grep -qiE "timed out|refused|not permitted|unreachable"; then
        emit_result "$probe_name" "Prevented"
        return
    fi

    if echo "$output" | grep -qi "exit code 1"; then
        log_audit_probe "$output"
        emit_result "$probe_name" "Prevented"
    else
        emit_result "$probe_name" "Unknown"
    fi
}

case "$LAYER_NAME" in
  baseline)
    INFO_LM="Baseline: No Isolation full communication between NGINX and Postgres should be possible."
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

log_audit_probe "[+] Probe - Intra-Tenant Lateral Movement A (NGINX -> Postgres)"
LATERAL_OUT_A=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- nc -zv -w 3 $POSTGRES_IP 5432; echo \"exit code \$?\"" 2>&1)

log_audit_probe "INFO: $INFO_LM"
log_audit_probe "$LATERAL_OUT_A"
classify_result "$LATERAL_OUT_A" "Intra-Tenant Lateral Movement A (NGINX -> Postgres)"
log_audit_probe "----------------------------------------------------"

log_audit_probe "[+] Probe - Intra-Tenant Lateral Movement B (Postgres -> NGINX)"
case "$LAYER_NAME" in
  baseline|layer_1)
    CMD="wget -S -T 3 -O /dev/null http://$NGINX_IP:80"
    ;;
  layer_2|layer_3)
    CMD="nc -zv -w 3 $NGINX_IP 8080"
    ;;
esac

LATERAL_OUT_B=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_BACK $POSTGRES_POD -- $CMD; echo \"exit code \$?\"" 2>&1)

log_audit_probe "INFO: $INFO_LM"
log_audit_probe "$LATERAL_OUT_B"
classify_result "$LATERAL_OUT_B" "Intra-Tenant Lateral Movement B (Postgres -> NGINX)"
log_audit_probe "----------------------------------------------------"

run_third_audit() {
    log_audit_probe "[+] Probe - Inter-Tenant Lateral Movement (Tenant-A NGINX -> Tenant-B NGINX)"
    [[ "$LAYER_NAME" == "layer_1" ]] && TARGET_PORT=80 || TARGET_PORT=8080

    LATERAL_OUT_C=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- nc -zv -w 3 $NGINX_B_IP $TARGET_PORT; echo \"exit code \$?\"" 2>&1)

    log_audit_probe "INFO: Inter Tenant Lateral Movement should be prevented through Network Policies and Capsule Namespace Isolation."
    log_audit_probe "$LATERAL_OUT_C"
    classify_result "$LATERAL_OUT_C" "Inter-Tenant Lateral Movement (Tenant-A NGINX -> Tenant-B NGINX)"
    log_audit_probe "----------------------------------------------------"
}

case "$LAYER_NAME" in
  layer_1|layer_2|layer_3) run_third_audit ;;
  *) log_audit_probe "[!] Skipping Inter-Tenant Probe for $LAYER_NAME." ;;
esac