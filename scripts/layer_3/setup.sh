#!/bin/bash
set -e

echo "Applying Layer 2 setup (Capsule + Tenant Replication) before Layer 3 installation..."
/root/layer_2/setup.sh

cd /root/layer_3

ln -sf /root/layer_2/workloads_gvisor.yaml /root/layer_3/workloads_gvisor.yaml
ln -sf /root/layer_2/workloads_containerd.yaml /root/layer_3/workloads_containerd.yaml

helm repo add cilium https://helm.cilium.io
helm repo update
echo "Installing Tetragon..."
helm upgrade --install tetragon cilium/tetragon -n kube-system

echo "Restarting Tetragon operator to ensure CRDs are reconciled..."
kubectl delete pod -n kube-system -l app.kubernetes.io/name=tetragon-operator --ignore-not-found || true
echo "Waiting for Tetragon CRDs to become available..."
sleep 10
kubectl wait --for condition=established --timeout=60s crd/tracingpolicies.cilium.io || true

echo "Waiting for Tetragon deployment to be ready..."
sleep 5
kubectl rollout status daemonset tetragon -n kube-system --timeout=120s || echo "Rollout status returned error, proceeding anyway..."

echo "Applying Layer 3 Security Policies (Tetragon Enforcements)..."
kubectl apply -f tetragon_policy.yaml || echo "Failed to apply tetragon policy."
sleep 5

echo "Installing Falco for Layer 3 (Runtime Threat Detection)..."
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update

echo "Creating and labeling Falco namespace for Privileged admission..."
kubectl create namespace falco --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace falco pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/enforce-version=latest --overwrite

echo "Installing Falco..."
cat <<EOF > falco-values.yaml
driver:
  kind: modern_ebpf
EOF

if [ -n "$HTTP_PROXY" ]; then
cat <<EOF >> falco-values.yaml
extraEnv:
  - name: HTTP_PROXY
    value: "$HTTP_PROXY"
  - name: HTTPS_PROXY
    value: "$HTTPS_PROXY"
  - name: NO_PROXY
    value: "$NO_PROXY"
falcoctl:
  artifact:
    install:
      env:
        - name: HTTP_PROXY
          value: "$HTTP_PROXY"
        - name: HTTPS_PROXY
          value: "$HTTPS_PROXY"
        - name: NO_PROXY
          value: "$NO_PROXY"
    follow:
      env:
        - name: HTTP_PROXY
          value: "$HTTP_PROXY"
        - name: HTTPS_PROXY
          value: "$HTTPS_PROXY"
        - name: NO_PROXY
          value: "$NO_PROXY"
EOF
fi

helm upgrade --install falco falcosecurity/falco \
  --namespace falco \
  -f falco-values.yaml \
  -f falco_rules.yaml

echo "Waiting for Falco deployment to be ready..."
sleep 5
kubectl rollout status daemonset falco -n falco --timeout=120s || echo "Falco rollout returned an error, proceeding anyway..."
