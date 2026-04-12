#!/bin/bash
# shellcheck source=./generic.sh
. "$(dirname "$0")/generic.sh"

SSH_OPTS="-q -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2"

case "$LAYER_NAME" in
  baseline|layer_1)
    INFO_RE="Baseline and Layer 1: OOM-Hog will succeed. ALLOCATION_SUCCESS will be true."
    ;;
  layer_2|layer_3)
    INFO_RE="Layer 2/3: K3s should trigger OOM-Killer. The Status should be \"OOMKilled\""
    ;;
  *)
    log_audit_probe "[!] ERROR: Unknown LAYER_NAME: $LAYER_NAME"
    exit 1
    ;;
esac

cleanup() {
    if [ -n "${HEALTH_PID:-}" ]; then
        kill "$HEALTH_PID" 2>/dev/null || true
    fi
    ssh $SSH_OPTS "$TARGET_USER"@"$TARGET_IP" "kubectl delete pod -n $NS_BACK stress-test --force --grace-period=0 >/dev/null 2>&1" || true
}

log_audit_probe "[+] Probe - Resource Exhaustion (DoS)"
ssh $SSH_OPTS "$TARGET_USER"@"$TARGET_IP" "kubectl delete events --all -n $NS_BACK > /dev/null 2>&1 || true"
log_audit_probe "INFO: $INFO_RE"

while true; do
  curl -s -o /dev/null -w "%{http_code}\n" http://"$TARGET_IP":"$NGINX_PORT" -m 2 || echo "CRASH"
  sleep 0.5
done >> "$RESULTS_DIR/health_monitor.log" &
HEALTH_PID=$!

MEMORY_GOAL=4096

APPLY_OUT=$(ssh $SSH_OPTS "$TARGET_USER"@"$TARGET_IP" << EOF
cat << 'STRESS' | kubectl apply -f - 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: stress-test
  namespace: $NS_BACK
spec:
  containers:
  - name: memory-hog
    image: vish/stress
    args:
    - --mem-total=${MEMORY_GOAL}M
    - --mem-alloc-size=256M
    - --mem-alloc-sleep=1s
  restartPolicy: Never
STRESS
EOF
)
log_audit_probe "Apply Output: $APPLY_OUT"

sleep 5
WAIT_TIME=0
MAX_WAIT=$(((MEMORY_GOAL / 256) + 15))
log_audit_probe "Waiting up to ${MAX_WAIT}s for memory allocation..."
ALLOCATION_SUCCESS=false

while [ "$WAIT_TIME" -lt "$MAX_WAIT" ]; do
    ALLOCATION_COUNT=$(ssh $SSH_OPTS "$TARGET_USER"@"$TARGET_IP" "kubectl logs stress-test -n $NS_BACK 2>/dev/null | grep -c 'Allocated' | tr -dc '0-9'" || echo "0" | tr -dc '0-9')
    if (( ALLOCATION_COUNT > 0 )); then
        log_audit_probe "[+] Pod completed its allocation successfully."
        ALLOCATION_SUCCESS=true
        break
    fi
    sleep 5
    WAIT_TIME=$((WAIT_TIME + 5))
    echo "Waiting for allocation... (${WAIT_TIME}s elapsed)"
done

if [[ "$ALLOCATION_SUCCESS" == "true" ]]; then
    log_audit_probe "[!] Pod is still Running. 4GB allocation successful and sustained."
elif
    [[ "$ALLOCATION_SUCCESS" == "false" ]]; then
    log_audit_probe "[!] Pod did not complete allocation within expected time. It may have been OOM-killed or failed to allocate."
fi

kill "$HEALTH_PID" 2>/dev/null || true
HEALTH_PID=""

TIMEOUT_COUNT=$(grep -c "CRASH" "$RESULTS_DIR/health_monitor.log" 2>/dev/null)
TIMEOUT_COUNT=${TIMEOUT_COUNT:-0}

OOM_EVENTS=$(ssh $SSH_OPTS "$TARGET_USER"@"$TARGET_IP" "kubectl get pod stress-test -n $NS_BACK -o jsonpath='{.status.containerStatuses[0].state.terminated.reason} {.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null" || true)
OOM_EVENTS=$(echo "$OOM_EVENTS" | xargs)
OOM_EVENTS=${OOM_EVENTS:-None}

OOM_EXIT_CODE=$(ssh $SSH_OPTS "$TARGET_USER"@"$TARGET_IP" "kubectl get pod stress-test -n $NS_BACK -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode} {.status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null" || true)
OOM_EXIT_CODE=$(echo "$OOM_EXIT_CODE" | xargs)
OOM_EXIT_CODE=${OOM_EXIT_CODE:-None}

log_audit_probe "Health Check Crashes: $TIMEOUT_COUNT"
log_audit_probe "Memory Hog Status: $OOM_EVENTS"
log_audit_probe "Memory Hog Exit Code: $OOM_EXIT_CODE"
log_audit_probe "Allocation Success: $ALLOCATION_SUCCESS"

if { [[ "$OOM_EVENTS" =~ "OOMKilled" ]] || [[ "$OOM_EXIT_CODE" =~ (^|[[:space:]])137($|[[:space:]]) ]]; } && [[ "$ALLOCATION_SUCCESS" == "false" ]] && ((TIMEOUT_COUNT == 0)); then
    emit_result "Resource Exhaustion (DoS)" "Prevented"
elif { [[ "$OOM_EVENTS" =~ "OOMKilled" ]] || [[ "$OOM_EXIT_CODE" =~ (^|[[:space:]])137($|[[:space:]]) ]]; } && [[ "$ALLOCATION_SUCCESS" == "false" ]]; then
    emit_result "Resource Exhaustion (DoS)" "Mitigated"
elif [[ "$ALLOCATION_SUCCESS" == "true" ]] && ((TIMEOUT_COUNT > 0)); then
    emit_result "Resource Exhaustion (DoS)" "Exploited"
elif [[ "$ALLOCATION_SUCCESS" == "true" ]]; then
    emit_result "Resource Exhaustion (DoS)" "Exploited"
else
    emit_result "Resource Exhaustion (DoS)" "Unknown"
fi

log_audit_probe "----------------------------------------------------"
cleanup