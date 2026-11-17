#!/usr/bin/env bash
# Create the local Kind cluster if absent, then install Calico and Traefik.
# Wait for networking and ingress readiness before deploying the application separately.
set -euo pipefail
cd "$(dirname "$0")/.."
for tool in docker kind kubectl helm curl; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
docker info >/dev/null
if ! kind get clusters | grep -qx echo-pong; then
  kind create cluster --name echo-pong --config k8s/local/kind.yaml
fi
context=kind-echo-pong
# Always select the intended cluster, regardless of the user's current context.
kubectl --context "$context" get nodes
if kubectl --context "$context" -n kube-system get daemonset kindnet >/dev/null 2>&1; then
  echo 'Existing cluster uses kindnet; recreate it explicitly with k8s/local/kind.yaml before installing Calico.' >&2
  exit 1
fi
manifest=$(mktemp)
trap 'rm -f "$manifest"' EXIT
curl --fail --silent --show-error --location --retry 3 \
  https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/calico.yaml \
  -o "$manifest"
kubectl --context "$context" apply --server-side -f "$manifest"
kubectl --context "$context" -n kube-system rollout status daemonset/calico-node --timeout=300s
kubectl --context "$context" -n kube-system rollout status deployment/calico-kube-controllers --timeout=300s
kubectl --context "$context" wait --for=condition=Ready nodes --all --timeout=180s
helm repo add traefik https://traefik.github.io/charts --force-update
helm repo update traefik
helm upgrade --install traefik traefik/traefik --version 42.4.0 \
  --kube-context "$context" --namespace traefik --create-namespace \
  --values k8s/local/traefik-values.yaml --skip-crds --wait --timeout 300s
printf '\nCluster ready. Load echo-pong:local, create the auth Secret, and apply k8s/overlays/local.\n'
printf 'Ingress: http://127.0.0.1:8080 (Host: echo-pong.localhost)\n'
