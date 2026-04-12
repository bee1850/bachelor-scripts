#!/bin/bash
set -e

cd /root/layer_1

if kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name 2>/dev/null | grep -qi capsule; then
    echo "Removing stale Capsule webhook configurations..."
    kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name \
        | grep -i capsule \
        | xargs -r kubectl delete --ignore-not-found
fi

echo "Adding Capsule Helm repository..."
helm repo add projectcapsule https://projectcapsule.github.io/charts
helm repo update

echo "Installing / Updating Capsule..."
helm upgrade --install capsule projectcapsule/capsule -n capsule-system --create-namespace --wait --timeout 5m

echo "Capsule version status:"
helm list -n capsule-system | grep capsule

echo "Waiting for Capsule deployment to be ready..."
kubectl rollout status deployment capsule-controller-manager -n capsule-system --timeout=90s

echo "Waiting for Capsule webhook service endpoints..."
kubectl wait --for=jsonpath='{.subsets[0].addresses[0].ip}' endpoints/capsule-webhook-service -n capsule-system --timeout=120s

echo "Applying Capsule Tenants and RBAC..."
kubectl apply -f tenant.yaml
kubectl apply -f tenant_rbac.yaml
sleep 5

CERT_DIR=~/.kube/tenant_certs
ALICE_KUBE="$CERT_DIR/alice-kubeconfig"
BOB_KUBE="$CERT_DIR/bob-kubeconfig"

echo "Checking Tenant User credentials..."
echo "Regenerating tenant user credentials to avoid stale kubeconfig identity drift..."
bash ../helpers/create_tenant_user.sh alice
bash ../helpers/create_tenant_user.sh bob

create_ns_idempotent() {
    local kube_config=$1
    local ns_name=$2
    if ! KUBECONFIG=$kube_config kubectl get ns "$ns_name" &>/dev/null; then
        KUBECONFIG=$kube_config kubectl create namespace "$ns_name"
    else
        echo "Namespace $ns_name already exists."
    fi
}

echo "Creating Namespaces as Tenant Owners (Self-Service)..."
create_ns_idempotent "$ALICE_KUBE" "tenant-a-frontend"
create_ns_idempotent "$ALICE_KUBE" "tenant-a-backend"
create_ns_idempotent "$BOB_KUBE" "tenant-b-frontend"
create_ns_idempotent "$BOB_KUBE" "tenant-b-backend"

echo "Verifying Capsule Adoption..."
sleep 5
kubectl get tenant tenant-a
kubectl get tenant tenant-b