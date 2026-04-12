#!/bin/bash

REMOTE_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
REMOTE_KUBE_PREFIX="export KUBECONFIG=$REMOTE_KUBECONFIG;"

echo "[*] Suppressing SSH banners..."
ssh -q "$TARGET_USER@$TARGET_IP" "touch ~/.hushlogin"

echo "[*] Performing Pre-Flight Cluster Health Check..."
HEALTH_CHECK=""
for _ in {1..24}; do
  HEALTH_CHECK=$(ssh -q "$TARGET_USER@$TARGET_IP" "$REMOTE_KUBE_PREFIX kubectl get nodes --no-headers 2>/dev/null | grep -E '[[:space:]]Ready([[:space:]]|$)'" || true)
  if [ -n "$HEALTH_CHECK" ]; then
    break
  fi
  sleep 5
done

if [ -z "$HEALTH_CHECK" ]; then
  echo "[!] ERROR: The Kubernetes cluster on $TARGET_IP is not Ready or API server is dead."
  echo "[!] Please ensure K3s is running and '$REMOTE_KUBE_PREFIX kubectl get nodes' works on the target."
  exit 1
fi
echo "[+] Cluster is healthy. Proceeding..."

echo "[*] Configuring Services and retrieving NodePorts..."

case "$LAYER_NAME" in
  baseline)
    NS_FRONT="default"
    NS_BACK="default"
    ;;
  layer_1|layer_2|layer_3)
    NS_FRONT="tenant-a-frontend"
    NS_BACK="tenant-a-backend"
    NS_B_FRONT="tenant-b-frontend"
    NS_B_BACK="tenant-b-backend"
    ;;
  *)
    echo "[!] ERROR: Unknown LAYER_NAME: $LAYER_NAME"
    exit 1
    ;;
esac

export NS_FRONT
export NS_BACK

if [ -n "$NS_B_FRONT" ]; then
  export NS_B_FRONT

ssh -q -T "$TARGET_USER@$TARGET_IP" << EOF
    export KUBECONFIG=$REMOTE_KUBECONFIG
    if [ "\$(kubectl get svc nginx-service -n $NS_B_FRONT -o jsonpath='{.spec.type}')" != "NodePort" ]; then
      kubectl patch svc nginx-service -n $NS_B_FRONT -p '{"spec": {"type": "NodePort"}}'
    fi
EOF
fi

if [ -n "$NS_B_BACK" ]; then
  export NS_B_BACK

ssh -q -T "$TARGET_USER@$TARGET_IP" << EOF
    export KUBECONFIG=$REMOTE_KUBECONFIG
    if [ "\$(kubectl get svc postgres-service -n $NS_B_BACK -o jsonpath='{.spec.type}')" != "NodePort" ]; then
      kubectl patch svc postgres-service -n $NS_B_BACK -p '{"spec": {"type": "NodePort"}}'
    fi
EOF
fi

ssh -q -T "$TARGET_USER@$TARGET_IP" << EOF
  export KUBECONFIG=$REMOTE_KUBECONFIG
  if [ "\$(kubectl get svc nginx-service -n $NS_FRONT -o jsonpath='{.spec.type}')" != "NodePort" ]; then
    kubectl patch svc nginx-service -n $NS_FRONT -p '{"spec": {"type": "NodePort"}}'
  fi
  
  if [ "\$(kubectl get svc postgres-service -n $NS_BACK -o jsonpath='{.spec.type}')" != "NodePort" ]; then
    kubectl patch svc postgres-service -n $NS_BACK -p '{"spec": {"type": "NodePort"}}'
  fi
EOF

POSTGRES_PORT=$(ssh -q "$TARGET_USER@$TARGET_IP" "$REMOTE_KUBE_PREFIX kubectl get svc postgres-service -n $NS_BACK -o jsonpath='{.spec.ports[0].nodePort}'")
NGINX_PORT=$(ssh -q "$TARGET_USER@$TARGET_IP" "$REMOTE_KUBE_PREFIX kubectl get svc nginx-service -n $NS_FRONT -o jsonpath='{.spec.ports[0].nodePort}'")
export POSTGRES_PORT
export NGINX_PORT
if [ -z "$POSTGRES_PORT" ] || [ -z "$NGINX_PORT" ]; then
  echo "[!] ERROR: Failed to retrieve NodePorts. Check if the services exist and are patched correctly."
  exit 1
fi

echo "[+] Postgres NodePort: $POSTGRES_PORT"
echo "[+] NGINX NodePort: $NGINX_PORT"