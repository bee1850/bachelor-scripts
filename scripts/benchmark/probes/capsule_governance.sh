#!/bin/bash
# shellcheck source=./generic.sh
. "$(dirname "$0")/generic.sh"

case "$LAYER_NAME" in
  baseline)
    emit_result "Capsule Tenant Governance" "Exploited"
    exit 0
    ;;
  layer_1|layer_2|layer_3)
    ;;
  *)
    log_audit_probe "[*] Skipping Capsule Governance probe for $LAYER_NAME (Capsule not deployed)."
    exit 0
    ;;
esac

CERT_DIR=~/.kube/tenant_certs
ALICE_KUBE="$CERT_DIR/alice-kubeconfig"
BOB_KUBE="$CERT_DIR/bob-kubeconfig"

log_audit_probe "   [+] Probe - Namespace Boundary: Can Alice create a 3rd namespace (quota=2)?"
BOUNDARY_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "KUBECONFIG=$ALICE_KUBE kubectl create namespace tenant-a-overflow" 2>&1) || true
if echo "$BOUNDARY_OUT" | grep -qi "forbidden\|cannot exceed\|quota\|error"; then
    log_audit_probe "       [PASS] Capsule rejected namespace creation beyond quota: $BOUNDARY_OUT"
    NS_BOUNDARY="PASS"
else
    log_audit_probe "       [FAIL] Namespace creation was not blocked: $BOUNDARY_OUT"
    NS_BOUNDARY="FAIL"
    ssh -q "$TARGET_USER"@"$TARGET_IP" "KUBECONFIG=$ALICE_KUBE kubectl delete namespace tenant-a-overflow --force --grace-period=0" > /dev/null 2>&1 || true
fi

log_audit_probe "   [+] Probe - Policy Inheritance: Does tenant-a-frontend auto-inherit NetworkPolicy + LimitRange?"
NP_COUNT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl get networkpolicies -n $NS_FRONT --no-headers 2>/dev/null | wc -l")
LR_COUNT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl get limitrange -n $NS_FRONT --no-headers 2>/dev/null | wc -l")

if [ "$NP_COUNT" -ge 1 ] && [ "$LR_COUNT" -ge 1 ]; then
    log_audit_probe "       [PASS] NetworkPolicies: $NP_COUNT, LimitRanges: $LR_COUNT"
    POLICY_INHERIT="PASS"
else
    log_audit_probe "       [FAIL] Missing inherited policies (NP: $NP_COUNT, LR: $LR_COUNT)"
    POLICY_INHERIT="FAIL"
fi

log_audit_probe "   [+] Probe - Cross-Tenant Visibility: Can Alice see Bob's namespaces?"
ALICE_NS_LIST=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "KUBECONFIG=$ALICE_KUBE kubectl get namespaces 2>&1")
if echo "$ALICE_NS_LIST" | grep -q "tenant-b"; then
    log_audit_probe "       [FAIL] Alice can see tenant-b namespaces:"
    log_audit_probe "$ALICE_NS_LIST"
    CROSS_TENANT_VIS="FAIL"
else
    log_audit_probe "       [PASS] Alice cannot see tenant-b namespaces"
    log_audit_probe "       Visible to Alice: $ALICE_NS_LIST"
    CROSS_TENANT_VIS="PASS"
fi

log_audit_probe "   [+] Probe - Cross-Tenant Manipulation: Can Alice deploy into $NS_B_BACK?"
CROSS_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "KUBECONFIG=$ALICE_KUBE kubectl run evil-pod --image=alpine -n $NS_B_BACK -- sleep 3600" 2>&1) || true
if echo "$CROSS_OUT" | grep -qi "forbidden\|cannot\|error\|not found"; then
    log_audit_probe "       [PASS] Capsule rejected cross-tenant deployment: $CROSS_OUT"
    CROSS_TENANT_MANIP="PASS"
else
    log_audit_probe "       [FAIL] Cross-tenant deployment was not blocked: $CROSS_OUT"
    CROSS_TENANT_MANIP="FAIL"
    ssh -q "$TARGET_USER"@"$TARGET_IP" "KUBECONFIG=$ALICE_KUBE kubectl delete pod evil-pod -n $NS_B_BACK --force --grace-period=0" > /dev/null 2>&1 || true
fi

FAIL_COUNT=0
[ "$NS_BOUNDARY" = "FAIL" ] && FAIL_COUNT=$((FAIL_COUNT+1))
[ "$POLICY_INHERIT" = "FAIL" ] && FAIL_COUNT=$((FAIL_COUNT+1))
[ "$CROSS_TENANT_VIS" = "FAIL" ] && FAIL_COUNT=$((FAIL_COUNT+1))
[ "$CROSS_TENANT_MANIP" = "FAIL" ] && FAIL_COUNT=$((FAIL_COUNT+1))

if [ "$FAIL_COUNT" -eq 0 ]; then
    emit_result "Capsule Tenant Governance" "Prevented"
elif [ "$FAIL_COUNT" -le 2 ]; then
    emit_result "Capsule Tenant Governance" "Mitigated"
else
    emit_result "Capsule Tenant Governance" "Exploited"
fi