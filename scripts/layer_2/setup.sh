#!/bin/bash
set -e

echo "Applying Layer 1 setup (Capsule) before Layer 2 installation..."
/root/layer_1/setup.sh

cd /root/layer_2

kubectl apply -f setup_namespace.yaml

# Apply Pod Security Labels in Layer 2
echo "Applying Pod Security labels..."
for ns in tenant-a-frontend tenant-a-backend tenant-b-frontend tenant-b-backend; do
	kubectl label namespace $ns pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/enforce-version=latest --overwrite
done

# Apply Tenant Replication
echo "Applying Tenant Replication..."
kubectl apply -f tenant_replication.yaml
kubectl get TenantResource -A
