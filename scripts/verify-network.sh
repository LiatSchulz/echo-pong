#!/usr/bin/env bash
# Verify denied foreign ingress and application-pod egress using positive controls.
# Create temporary diagnostics and an allow policy, then remove them on exit.
set -euo pipefail
context=kind-echo-pong
namespace=echo-pong-netcheck
k() { kubectl --context "$context" "$@"; }
k -n echo-pong rollout status deployment/echo-pong --timeout=180s
cleanup() {
  k -n echo-pong delete networkpolicy allow-netcheck --ignore-not-found >/dev/null
  k delete namespace "$namespace" --ignore-not-found --wait=false >/dev/null
}
if k get namespace "$namespace" >/dev/null 2>&1; then
  echo "Namespace $namespace already exists; remove it after checking its contents." >&2
  exit 1
fi
trap cleanup EXIT
k create namespace "$namespace"
k -n "$namespace" run sink --image=busybox:1.37.0 --restart=Never \
  --command -- sh -c 'mkdir -p /tmp/www; echo reachable > /tmp/www/index.html; httpd -f -p 8080 -h /tmp/www'
k -n "$namespace" run client --image=curlimages/curl:8.17.0 --restart=Never \
  --command -- sleep 1800
k -n "$namespace" wait --for=condition=Ready pod/sink pod/client --timeout=180s
sink_ip=$(k -n "$namespace" get pod sink -o jsonpath='{.status.podIP}')
app_ip=$(k -n echo-pong get service echo-pong -o jsonpath='{.spec.clusterIP}')
curl_from_client() { k -n "$namespace" exec client -- curl -fsS --connect-timeout 3 --max-time 5 "$@"; }
curl_from_client "http://$sink_ip:8080/"
# Establish real connectivity from this exact foreign pod before testing denial.
cat <<EOF | k apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-netcheck
  namespace: echo-pong
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: echo-pong
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: $namespace
      ports:
        - protocol: TCP
          port: 8080
EOF
for attempt in $(seq 1 15); do
  if curl_from_client "http://$app_ip/health"; then break; fi
  if [ "$attempt" = 15 ]; then echo 'Positive ingress control failed' >&2; exit 1; fi
  sleep 1
done
k -n echo-pong delete networkpolicy allow-netcheck
sleep 3
set +e
blocked=$(curl_from_client "http://$app_ip/health" 2>&1)
status=$?
set -e
if [ "$status" -ne 28 ]; then
  printf 'Expected timeout (28) for denied foreign ingress; got %s: %s\n' "$status" "$blocked" >&2
  exit 1
fi
echo 'PASS: foreign ingress blocked after successful same-pod positive control'
# Ephemeral container shares the actual application pod network namespace.
# It does not change the application image or its filesystem.
app_pod=$(k -n echo-pong get pods -l app.kubernetes.io/name=echo-pong \
  -o jsonpath='{.items[0].metadata.name}')
set +e
egress=$(k -n echo-pong debug "pod/$app_pod" --attach=true \
  --container="egress-check-$(date +%s)" --image=curlimages/curl:8.17.0 \
  --profile=restricted -- curl -fsS --connect-timeout 3 --max-time 5 "http://$sink_ip:8080/" 2>&1)
status=$?
set -e
printf '%s\n' "$egress"
# kubectl debug does not consistently propagate the process exit code.
if ! printf '%s' "$egress" | grep -q 'curl: (28)'; then
  echo "Expected curl timeout from the actual app pod network namespace (kubectl status $status)" >&2
  exit 1
fi
echo 'PASS: application-pod egress blocked; destination reachable from control pod'
