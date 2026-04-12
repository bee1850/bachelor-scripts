#!/bin/bash

K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
if [ -f "$K3S_KUBECONFIG" ]; then
    export KUBECONFIG="$K3S_KUBECONFIG"
fi

echo "======================================================="
echo " CLUSTER CLEANUP"
echo "======================================================="

falco_installed=false
if helm list -A -q | grep -q "^falco$"; then
    falco_installed=true
fi

capsule_installed=false
if helm list -A -q | grep -q "^capsule$"; then
    capsule_installed=true
fi

tetragon_installed=false
if helm list -A -q | grep -q "^tetragon$"; then
    tetragon_installed=true
fi

echo "Disabling Capsule Webhooks to prevent API lockup..."
kubectl delete mutatingwebhookconfiguration -l app.kubernetes.io/instance=capsule --ignore-not-found || true
kubectl delete validatingwebhookconfiguration -l app.kubernetes.io/instance=capsule --ignore-not-found || true
kubectl get mutatingwebhookconfiguration,validatingwebhookconfiguration -o name 2>/dev/null \
    | grep -i capsule \
    | xargs -r kubectl delete --ignore-not-found || true

if [ "$capsule_installed" = true ]; then
    echo "Removing Capsule custom resources..."
    kubectl delete tenantresource --all -A --ignore-not-found
    kubectl delete tenant --all --ignore-not-found
fi
if [ "$tetragon_installed" = true ]; then
    echo "Removing Tetragon custom resources..."
    kubectl delete tracingpolicy --all -A --ignore-not-found
    kubectl delete tracingpoliciesnamespaced --all -A --ignore-not-found
fi
if [ "$falco_installed" = true ]; then
    echo "Removing Falco custom Rules..."
    kubectl delete -f /root/layer_3/falco_rules.yaml --ignore-not-found 2>/dev/null || true
fi
echo "Removing tenant namespaces..."
TENANT_NS="tenant-a-frontend tenant-a-backend tenant-b-frontend tenant-b-backend tenant-frontend tenant-backend"
for ns in $TENANT_NS; do
    if kubectl get ns "$ns" &>/dev/null; then
        echo "  -> Deleting $ns"
        kubectl patch ns "$ns" -p '{"spec":{"finalizers":null}}' --type=merge 2>/dev/null || true
        kubectl delete ns "$ns" --timeout=15s --ignore-not-found || true
    fi
done

echo "Uninstalling Helm releases..."
if [ "$capsule_installed" = true ]; then
helm uninstall capsule -n capsule-system --wait --timeout=60s || true
fi
if [ "$falco_installed" = true ]; then
helm uninstall falco -n falco --wait --timeout=60s || true
fi
if [ "$tetragon_installed" = true ]; then
helm uninstall tetragon -n kube-system --wait --timeout=60s || true
fi

echo "Removing tooling namespaces..."
for ns in falco capsule-system; do
    kubectl patch ns "$ns" -p '{"spec":{"finalizers":null}}' --type=merge 2>/dev/null || true
    kubectl delete ns "$ns" --ignore-not-found || true
done

echo "Removing all remaining CRDs..."
if [ "$capsule_installed" = true ]; then
kubectl get crd -o name | grep capsule.clastix.io | xargs -r kubectl delete --ignore-not-found || true
fi

if [ "$tetragon_installed" = true ]; then
kubectl delete crd tracingpolicies.cilium.io tracingpoliciesnamespaced.cilium.io --ignore-not-found || true
fi

echo "Removing Capsule RBAC..."
if [ "$capsule_installed" = true ]; then
kubectl delete clusterrolebinding capsule-provisioner-binding --ignore-not-found || true

kubectl delete clusterrole -l app.kubernetes.io/instance=capsule --ignore-not-found || true
fi

echo "Cleaning up default namespace..."
kubectl delete deployment --all -n default --ignore-not-found || true
kubectl delete svc -n default $(kubectl get svc -n default -o name | grep -v 'service/kubernetes') --ignore-not-found 2>/dev/null || true
kubectl delete pods --all -n default --force --grace-period=0 --ignore-not-found 2>/dev/null || true

echo "======================================================="
echo " Cleanup complete."
echo "======================================================="