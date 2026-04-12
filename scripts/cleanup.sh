#!/bin/bash

echo "======================================================="
echo " CLUSTER CLEANUP"
echo "======================================================="

# --- Step 1: Delete Capsule CRs ---
echo "[1] Removing Capsule custom resources..."
kubectl delete tenantresource --all -A --timeout=30s --ignore-not-found
kubectl delete tenant tenant-a tenant-b --timeout=30s --ignore-not-found

# --- Step 2: Delete Tetragon / Falco policies ---
echo "[2] Removing Tetragon and Falco policies..."
kubectl delete TracingPolicy --all --timeout=30s --ignore-not-found
kubectl delete -f /root/layer_3/tetragon_policy.yaml --ignore-not-found 2>/dev/null || true
kubectl delete -f /root/layer_3/falco_rules.yaml --ignore-not-found 2>/dev/null || true

# --- Step 3: Uninstall Helm releases ---
echo "[3] Uninstalling Helm releases..."
# Uninstall Capsule first and wait for its pods to fully terminate before
# touching namespaces — otherwise the still-running webhook re-adds finalizers.
helm uninstall capsule  -n capsule-system --wait --timeout=60s || true
kubectl wait --for=delete pod -l app.kubernetes.io/instance=capsule \
    -n capsule-system --timeout=60s 2>/dev/null || true
helm uninstall tetragon -n kube-system --wait --timeout=60s || true
helm uninstall falco -n falco --wait --timeout=60s || true

# --- Step 4: Delete tenant + tooling namespaces ---
echo "[4] Removing tenant namespaces..."
TENANT_NS="tenant-a-frontend tenant-a-backend tenant-b-frontend tenant-b-backend tenant-frontend tenant-backend"
for ns in $TENANT_NS; do
    if kubectl get ns "$ns" &>/dev/null; then
        # Clear both metadata and spec finalizers together to avoid race with
        # a still-terminating Capsule webhook re-adding them.
        kubectl patch ns "$ns" \
            -p '{"metadata":{"finalizers":null},"spec":{"finalizers":[]}}' \
            --type=merge 2>/dev/null || true
        kubectl delete ns "$ns" --timeout=30s --ignore-not-found || {
            echo "  [!] $ns stuck — forcing finalizer removal and retrying..."
            kubectl patch ns "$ns" \
                -p '{"metadata":{"finalizers":null},"spec":{"finalizers":[]}}' \
                --type=merge 2>/dev/null || true
            kubectl delete ns "$ns" --timeout=20s --ignore-not-found || true
        }
    else
        echo "  [skip] $ns not found"
    fi
done

echo "[4b] Removing tooling namespaces..."
for ns in falco capsule-system; do
    kubectl delete ns "$ns" --timeout=30s --ignore-not-found || {
        kubectl patch ns "$ns" -p '{"spec":{"finalizers":null}}' --type=merge 2>/dev/null || true
        kubectl delete ns "$ns" --timeout=20s --ignore-not-found || true
    }
done

# --- Step 5: Clean up Capsule CRDs ---
echo "[5] Removing Capsule CRDs..."
kubectl get crd -o name | grep capsule.clastix.io | xargs -r kubectl delete --ignore-not-found --timeout=30s || true

# --- Step 6: Clean up Tetragon CRDs ---
echo "[6] Removing Tetragon CRDs..."
kubectl delete crd tracingpolicies.cilium.io tracingpoliciesnamespaced.cilium.io \
    --ignore-not-found --timeout=30s || true

# --- Step 7: Remove Capsule RBAC ---
echo "[7] Removing Capsule RBAC..."
kubectl delete clusterrolebinding capsule-provisioner-binding --ignore-not-found || true

# --- Step 8: Clean up workloads deployed to default namespace (baseline) ---
echo "[8] Cleaning up default namespace workloads..."
kubectl delete deployment --all -n default --ignore-not-found || true
kubectl delete svc -n default \
    $(kubectl get svc -n default -o name 2>/dev/null | grep -v 'service/kubernetes') \
    --ignore-not-found 2>/dev/null || true
kubectl delete pods --all -n default --force --grace-period=0 --ignore-not-found 2>/dev/null || true

# --- Step 9: Remove Tetragon daemonset if left in kube-system ---
echo "[9] Removing Tetragon daemonset from kube-system..."
kubectl delete ds tetragon -n kube-system --ignore-not-found || true

echo ""
echo "======================================================="
echo " Cleanup complete."
echo "======================================================="