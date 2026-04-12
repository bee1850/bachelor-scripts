#!/bin/bash

# shellcheck source=./probes/generic.sh
. ./probes/generic.sh

log_audit_probe "======================================================="
log_audit_probe " 2. AUTOMATED SECURITY AUDIT - $LAYER_NAME | $RUNTIME"
log_audit_probe "======================================================="
log_audit_probe "[*] Executing Security Audit Probes..."
AUDIT_FILE="$RESULTS_DIR/security_audit.txt"
export AUDIT_FILE
RESULTS_CSV="$RESULTS_DIR/security_results.csv"
export RESULTS_CSV
# Write CSV header (overwrite previous run)
echo "layer,runtime,probe,outcome" > "$RESULTS_CSV"

# Namespaces 1
NGINX_POD=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl get pods -l app=nginx -n $NS_FRONT -o jsonpath='{.items[0].metadata.name}'")
export NGINX_POD
NGINX_IP=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl get pods -l app=nginx -n $NS_FRONT -o jsonpath='{.items[0].status.podIP}'")
export NGINX_IP
POSTGRES_POD=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl get pods -l app=postgres -n $NS_BACK -o jsonpath='{.items[0].metadata.name}'")
export POSTGRES_POD
POSTGRES_IP=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl get pods -l app=postgres -n $NS_BACK -o jsonpath='{.items[0].status.podIP}'")
export POSTGRES_IP


# Namespace 2 variables (only for layer 2 and 3)
if [ -n "$NS_B_FRONT" ] && [ -n "$NS_B_BACK" ]; then
  NGINX_B_POD=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl get pods -l app=nginx -n $NS_B_FRONT -o jsonpath='{.items[0].metadata.name}'")
  export NGINX_B_POD
  NGINX_B_IP=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl get pods -l app=nginx -n $NS_B_FRONT -o jsonpath='{.items[0].status.podIP}'")
  export NGINX_B_IP
  POSTGRES_B_POD=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl get pods -l app=postgres -n $NS_B_BACK -o jsonpath='{.items[0].metadata.name}'")
  export POSTGRES_B_POD
  POSTGRES_B_IP=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl get pods -l app=postgres -n $NS_B_BACK -o jsonpath='{.items[0].status.podIP}'")
  export POSTGRES_B_IP
fi

log_audit_probe "=== SECURITY AUDIT ($LAYER_NAME | $RUNTIME) ==="
log_audit_probe "Timestamp: $(date)"
log_audit_probe "--- CLUSTER TOPOLOGY ---"
log_audit_probe "Nginx Pod: $NGINX_POD ($NGINX_IP)"
log_audit_probe "Postgres Pod: $POSTGRES_POD ($POSTGRES_IP)"
log_audit_probe ""
./probes/kernel_visibility.sh
log_audit_probe ""
./probes/lateral_movement.sh
log_audit_probe ""
./probes/host_path_mounting.sh
log_audit_probe ""
./probes/capabilities.sh
log_audit_probe ""
./probes/syscall_isolation.sh
log_audit_probe ""
./probes/filesystem_isolation.sh
log_audit_probe ""
./probes/cgroup_device_mounting.sh
log_audit_probe ""
./probes/information_disclosure.sh
log_audit_probe ""
./probes/resource_exhaustion.sh
log_audit_probe ""
./probes/cluster_reconnaissance.sh
log_audit_probe ""
./probes/procfs_sysfs_leakage.sh
log_audit_probe ""
./probes/threat_detection.sh
log_audit_probe ""
./probes/capsule_governance.sh


echo "[*] Security Audit saved to: $AUDIT_FILE"
echo "[*] Security Results CSV saved to: $RESULTS_CSV"
echo ""
echo "=== RESULT SUMMARY ==="
column -t -s',' "$RESULTS_CSV"