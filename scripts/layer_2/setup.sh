#!/bin/bash
set -e

echo "Applying Layer 1 setup (Capsule) before Layer 2 installation..."
/root/layer_1/setup.sh

cd /root/layer_2

kubectl apply -f setup_namespace.yaml

# Apply Tenant Replication
echo "Applying Tenant Replication..."
kubectl apply -f tenant_replication.yaml
kubectl get TenantResource -A
