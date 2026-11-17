#!/usr/bin/env bash
set -euo pipefail
set +x
cd "$(dirname "$0")/.."
mode="${1:-overview}"
context=kind-echo-pong
url=http://127.0.0.1:8080
host=echo-pong.localhost

section() { printf '\n%s\n' "$1"; }
overview() {
  test -r secrets/token || { echo 'Missing secrets/token; see k8s/README.md.' >&2; exit 1; }
  section 'Container runtime and Kubernetes node'
  colima status
  docker ps --filter name=echo-pong-control-plane
  kubectl --context "$context" get nodes -o wide
  section 'Application resources'
  kubectl --context "$context" -n echo-pong get deploy,pods,svc,ingress,pdb,networkpolicy
  section 'Public health through ingress'
  curl --fail --silent --show-error -H "Host: $host" "$url/health"
  section 'Protected endpoint without credentials (expected HTTP 401)'
  status=$(curl --silent --show-error -o /dev/null -w '%{http_code}' -H "Host: $host" "$url/ping")
  printf 'HTTP %s\n' "$status"
  test "$status" = 401 || { echo 'Unexpected authentication response' >&2; exit 1; }
  section 'Authenticated ping through ingress'
  { printf 'Authorization: Bearer '; tr -d '\n' < secrets/token; printf '\n'; } |
    curl --fail --silent --show-error --header @- -H "Host: $host" "$url/ping"
  section 'Pod and container security settings'
  kubectl --context "$context" -n echo-pong get deployment echo-pong \
    -o jsonpath='{.spec.template.spec.securityContext}{"\n"}{.spec.template.spec.containers[0].securityContext}{"\n"}'
}
rollout() { python3 scripts/check-rollout.py --url "$url"; }
network() { scripts/verify-network.sh; }
case "$mode" in
  overview) overview ;;
  rollout) rollout ;;
  network) network ;;
  all) overview; rollout; network ;;
  *) echo 'Usage: scripts/demo.sh [overview|rollout|network|all]' >&2; exit 2 ;;
esac
