#!/bin/bash
# shellcheck source=./generic.sh
. "$(dirname "$0")/generic.sh"

# Map the LAYER_NAME to the appropriate expected security properties for the audit report
case "$LAYER_NAME" in
  baseline|layer_1)
    INFO_RE="Baseline and Layer 1: OOM-Hog will succeed and SystemOOM Events will be triggered. The Status should be \"SystemOOM\""
    ;;
  layer_2|layer_3)
    INFO_RE="Layer 2/3: K3s should trigger OOM-Killer. The Status should be \"OOMKilled\""
    ;;
  *)
    log_audit_probe "[!] ERROR: Unknown LAYER_NAME: $LAYER_NAME"
    exit 1
    ;;
esac

log_audit_probe "[+] Probe - Resource Exhaustion (DoS)" 
ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl delete events --all -n $NS_FRONT > /dev/null 2>&1 || true"
log_audit_probe "INFO: $INFO_RE"
while true; do 
  curl -s -o /dev/null -w "%{http_code}\n" http://"$TARGET_IP":"$NGINX_PORT" -m 2 || echo "CRASH"
  sleep 0.5
done >> "$RESULTS_DIR/health_monitor.log" &
HEALTH_PID=$!
APPLY_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" << EOF
cat << 'STRESS' | kubectl apply -f - 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: stress-test
  namespace: $NS_FRONT
spec:
  containers:
  - name: memory-hog
    restartPolicy: Never
    image: polinux/stress 
    command: ["stress"]
    args: ["--vm", "30", "--vm-bytes", "1G", "--vm-hang", "0"] 
STRESS
EOF
)
sleep 45
kill $HEALTH_PID 2>/dev/null

TIMEOUT_COUNT=$(grep -c "CRASH" "$RESULTS_DIR/health_monitor.log")
OOM_EVENTS=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl get pod stress-test -n $NS_FRONT -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'")
OOM_EVENTS2=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl get events -n $NS_FRONT")
log_audit_probe "Apply Output: $APPLY_OUT"
log_audit_probe "Health Check Crashes: $TIMEOUT_COUNT"
log_audit_probe "Memory Hog Status: $OOM_EVENTS"
log_audit_probe "OOM Events (Detailed):"
log_audit_probe "$OOM_EVENTS2"

# Self-classify
if echo "$OOM_EVENTS2" | grep -qi "SystemOOM\|OOMKilling"; then
    emit_result "Resource Exhaustion (DoS)" "Exploited"
elif  echo "$OOM_EVENTS" | grep -qi "OOMKilled"; then
    emit_result "Resource Exhaustion (DoS)" "Mitigated"
elif [ "$TIMEOUT_COUNT" -gt 0 ]; then
    emit_result "Resource Exhaustion (DoS)" "Exploited"
else
    emit_result "Resource Exhaustion (DoS)" "Unknown"
fi
log_audit_probe "----------------------------------------------------"
ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl delete pod -n $NS_FRONT stress-test --force --grace-period=0" > /dev/null 2>&1 || true