#!/bin/bash
set -e

USER_NAME=${1:-alice}
GROUP=${2:-projectcapsule.dev}
CERT_DIR=~/.kube/tenant_certs
mkdir -p $CERT_DIR

echo "Generating private key and CSR for $USER_NAME..."
openssl genrsa -out $CERT_DIR/"$USER_NAME".key 2048
openssl req -new -key $CERT_DIR/"$USER_NAME".key -out $CERT_DIR/"$USER_NAME".csr -subj "/CN=$USER_NAME/O=$GROUP"

echo "Cleaning up existing CSR for $USER_NAME..."
kubectl delete csr "$USER_NAME"-csr --ignore-not-found || true

echo "Creating Kubernetes CSR..."
CSR_REQ=$(cat "$CERT_DIR/$USER_NAME.csr" | base64 | tr -d '\n')
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: "$USER_NAME-csr"
spec:
  request: $CSR_REQ
  signerName: kubernetes.io/kube-apiserver-client
  usages:
  - client auth
EOF

echo "Approving CSR..."
kubectl certificate approve "$USER_NAME"-csr

echo "Fetching signed certificate..."
kubectl get csr "$USER_NAME"-csr -o jsonpath='{.status.certificate}' | base64 --decode > $CERT_DIR/"$USER_NAME".crt

echo "Generating Kubeconfig for $USER_NAME..."
CLUSTER_NAME=$(kubectl config view -o jsonpath='{.clusters[0].name}')
SERVER=$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')
CA_DATA=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

cat <<EOF > $CERT_DIR/"$USER_NAME"-kubeconfig
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: $CA_DATA
    server: $SERVER
  name: $CLUSTER_NAME
users:
- name: $USER_NAME
  user:
    client-certificate: $CERT_DIR/$USER_NAME.crt
    client-key: $CERT_DIR/$USER_NAME.key
contexts:
- context:
    cluster: $CLUSTER_NAME
    user: $USER_NAME
  name: $USER_NAME-context
current-context: $USER_NAME-context
EOF

echo "Done! You can use the generated kubeconfig like this:"
echo "export KUBECONFIG=$CERT_DIR/$USER_NAME-kubeconfig"
echo "kubectl get namespaces"
