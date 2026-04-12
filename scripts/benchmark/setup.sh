#!/bin/bash

echo "[*] Suppressing SSH banners..."
ssh -q "$TARGET_USER@$TARGET_IP" "touch ~/.hushlogin"

echo "[*] Performing Pre-Flight Cluster Health Check..."
HEALTH_CHECK=$(ssh -q "$TARGET_USER@$TARGET_IP" "kubectl get nodes | grep ' Ready'")
if [ -z "$HEALTH_CHECK" ]; then
  echo "[!] ERROR: The Kubernetes cluster on $TARGET_IP is not Ready or API server is dead."
  echo "[!] Please reboot the target NUC and ensure 'kubectl get nodes' works before running."
  exit 1
fi
echo "[+] Cluster is healthy. Proceeding..."

echo "[*] Configuring Services and retrieving NodePorts..."

# 1. Map the LAYER_NAME to the appropriate namespaces
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
    if [ "\$(kubectl get svc nginx-service -n $NS_B_FRONT -o jsonpath='{.spec.type}')" != "NodePort" ]; then
      kubectl patch svc nginx-service -n $NS_B_FRONT -p '{"spec": {"type": "NodePort"}}'
    fi
EOF
fi

if [ -n "$NS_B_BACK" ]; then
  export NS_B_BACK

ssh -q -T "$TARGET_USER@$TARGET_IP" << EOF
    if [ "\$(kubectl get svc postgres-service -n $NS_B_BACK -o jsonpath='{.spec.type}')" != "NodePort" ]; then
      kubectl patch svc postgres-service -n $NS_B_BACK -p '{"spec": {"type": "NodePort"}}'
    fi
EOF
fi

# 2. Run the patching logic once, injecting our namespace variables
# Note: Using unquoted << EOF allows local variables ($NS_FRONT) to expand before sending, 
# while escaping \$() ensures kubectl runs on the remote machine.
ssh -q -T "$TARGET_USER@$TARGET_IP" << EOF
  if [ "\$(kubectl get svc nginx-service -n $NS_FRONT -o jsonpath='{.spec.type}')" != "NodePort" ]; then
    kubectl patch svc nginx-service -n $NS_FRONT -p '{"spec": {"type": "NodePort"}}'
  fi
  
  if [ "\$(kubectl get svc postgres-service -n $NS_BACK -o jsonpath='{.spec.type}')" != "NodePort" ]; then
    kubectl patch svc postgres-service -n $NS_BACK -p '{"spec": {"type": "NodePort"}}'
  fi
EOF


# 3. Retrieve the ports
POSTGRES_PORT=$(ssh -q "$TARGET_USER@$TARGET_IP" "kubectl get svc postgres-service -n $NS_BACK -o jsonpath='{.spec.ports[0].nodePort}'")
NGINX_PORT=$(ssh -q "$TARGET_USER@$TARGET_IP" "kubectl get svc nginx-service -n $NS_FRONT -o jsonpath='{.spec.ports[0].nodePort}'")
export POSTGRES_PORT
export NGINX_PORT
if [ -z "$POSTGRES_PORT" ] || [ -z "$NGINX_PORT" ]; then
  echo "[!] ERROR: Failed to retrieve NodePorts. Check if the services exist and are patched correctly."
  exit 1
fi

echo "[+] Postgres NodePort: $POSTGRES_PORT"
echo "[+] Nginx NodePort: $NGINX_PORT"