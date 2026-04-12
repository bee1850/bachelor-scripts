#!/bin/bash
set -e

cd /root/layer_1

# Add Capsule Repo and Install
echo "Adding Capsule Helm repository..."
helm repo add projectcapsule https://projectcapsule.github.io/charts
helm repo update

echo "Installing / Updating Capsule..."
helm upgrade --install capsule projectcapsule/capsule -n capsule-system --create-namespace

echo "Capsule version status:"
helm list -n capsule-system | grep capsule

# Wait for Capsule webhook to be ready
echo "Waiting for Capsule deployment to be ready..."
kubectl rollout status deployment capsule-controller-manager -n capsule-system --timeout=90s

# Apply Capsule Tenants and RBAC
echo "Applying Capsule Tenants and RBAC..."
kubectl apply -f tenant.yaml
kubectl apply -f tenant_rbac.yaml
sleep 5

CERT_DIR=~/.kube/tenant_certs
ALICE_KUBE="$CERT_DIR/alice-kubeconfig"
BOB_KUBE="$CERT_DIR/bob-kubeconfig"

echo "Checking Tenant User credentials..."
[ ! -f "$ALICE_KUBE" ] && bash ../helpers/create_tenant_user.sh alice || echo "Alice creds exist."
[ ! -f "$BOB_KUBE" ] && bash ../helpers/create_tenant_user.sh bob || echo "Bob creds exist."

create_ns_idempotent() {
    local kube_config=$1
    local ns_name=$2
    if ! KUBECONFIG=$kube_config kubectl get ns "$ns_name" &>/dev/null; then
        KUBECONFIG=$kube_config kubectl create namespace "$ns_name"
    else
        echo "Namespace $ns_name already exists."
    fi
}

# --- CONDITIONAL NAMESPACE CREATION ---
echo "Creating Namespaces as Tenant Owners (Self-Service)..."
create_ns_idempotent "$ALICE_KUBE" "tenant-a-frontend"
create_ns_idempotent "$ALICE_KUBE" "tenant-a-backend"
create_ns_idempotent "$BOB_KUBE" "tenant-b-frontend"
create_ns_idempotent "$BOB_KUBE" "tenant-b-backend"

# Verify Capsule Adoption
echo "Verifying Capsule Adoption..."
sleep 5
kubectl get tenant tenant-a
kubectl get tenant tenant-b