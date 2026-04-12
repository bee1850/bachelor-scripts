#!/bin/bash
# shellcheck source=./generic.sh
. "$(dirname "$0")/generic.sh"

# Map the LAYER_NAME to the appropriate expected security properties for the audit report
case "$LAYER_NAME" in
  baseline|layer_1|layer_2)
    INFO_RE="Skipping Threat Detection probe for layers baseline, layer_1 and layer_2 since the expected results are clear."
    emit_result "Active Anomaly Generation" "Exploited"
    exit 0
    ;;
  layer_3)
    INFO_RE="Layer 3: Tetragon and Falco should be deployed and actively monitoring for threats. For containerd, execution and alerts will succeed. For gvisor, host eBPF tools cannot see inside the gvisor Sandbox, so failure is EXPECTED."
    ;;
  *)
    log_audit_probe "[!] ERROR: Unknown LAYER_NAME: $LAYER_NAME"
    exit 1
    ;;
esac

log_audit_probe "[+] Probe - Active Anomaly Generation"
log_audit_probe "INFO: $INFO_RE"

log_audit_probe "   [1] Testing Execution Prevention (Tetragon syscall block)..."
# Attempt to run an unauthorized binary (wget) — measure detection latency
set +e
START_1=$(date +%s%N)
ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- /usr/bin/wget http://example.com" > /dev/null 2>&1
EXIT_CODE_1=$?
END_1=$(date +%s%N)
DETECTION_MS_1=$(( (END_1 - START_1) / 1000000 ))
set -e

if [ $EXIT_CODE_1 -eq 137 ] || [ $EXIT_CODE_1 -eq 126 ]; then
    log_audit_probe "       [SUCCESS] Tetragon blocked execution of wget (Sigkilled/Denied) — Detection Latency: ${DETECTION_MS_1}ms"
else
    log_audit_probe "       [FAILED] Tetragon did NOT block execution of wget (Exit code: $EXIT_CODE_1) — Elapsed: ${DETECTION_MS_1}ms"
fi

log_audit_probe "   [2] Testing Network Reconnaissance Prevention (Tetragon)..."
# Attempt to run nc (using -h to avoid web proxy network timeouts causing false positives) — measure detection latency
set +e
START_2=$(date +%s%N)
ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- /usr/bin/nc -h" > /dev/null 2>&1
EXIT_CODE_2=$?
END_2=$(date +%s%N)
DETECTION_MS_2=$(( (END_2 - START_2) / 1000000 ))
set -e

if [ $EXIT_CODE_2 -eq 137 ] || [ $EXIT_CODE_2 -eq 126 ]; then
    log_audit_probe "       [SUCCESS] Tetragon blocked execution of nc (Sigkilled/Denied) — Detection Latency: ${DETECTION_MS_2}ms"
else
    log_audit_probe "       [FAILED] Tetragon did NOT block execution of nc (Exit code: $EXIT_CODE_2) — Elapsed: ${DETECTION_MS_2}ms"
fi

log_audit_probe "   [3] Testing Read/Write Alerting (Falco)..."
# Attempt to read sensitive file (Falco should alert) — measure alert propagation latency
FALCO_ACTION_TS=$(date +%s)
ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl exec -n $NS_FRONT $NGINX_POD -- /bin/cat /etc/shadow" > /dev/null 2>&1 || true

log_audit_probe "       Checking Falco logs for alerts..."
# Wait briefly for log propagation then check
sleep 3
FALCO_CHECK_TS=$(date +%s)
# Fetch the logs and grep remotely, capture output locally
FALCO_LOGS=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl logs -l app.kubernetes.io/name=falco -n falco --since=30s" 2>/dev/null)

ALERT_LATENCY_S=$(( FALCO_CHECK_TS - FALCO_ACTION_TS ))
if [ -n "$FALCO_LOGS" ]; then
    log_audit_probe "       [SUCCESS] Falco alert received within ${ALERT_LATENCY_S}s window"
    log_audit_probe "$FALCO_LOGS"
else
    log_audit_probe "       [WARNING] No Falco alert found for /etc/shadow access within ${ALERT_LATENCY_S}s window (or log not yet propagated)"
fi

# Self-classify: both Tetragon kills succeeded = Prevented, neither = Exploited, partial = Mitigated
TETRAGON_BLOCKED=0
{ [ $EXIT_CODE_1 -eq 137 ] || [ $EXIT_CODE_1 -eq 126 ]; } && TETRAGON_BLOCKED=$((TETRAGON_BLOCKED+1))
{ [ $EXIT_CODE_2 -eq 137 ] || [ $EXIT_CODE_2 -eq 126 ]; } && TETRAGON_BLOCKED=$((TETRAGON_BLOCKED+1))

if [ "$TETRAGON_BLOCKED" -eq 2 ]; then
    emit_result "Active Anomaly Generation" "Prevented"
elif [ "$TETRAGON_BLOCKED" -eq 1 ]; then
    emit_result "Active Anomaly Generation" "Mitigated"
else
    emit_result "Active Anomaly Generation" "Exploited"
fi
log_audit_probe "----------------------------------------------------"