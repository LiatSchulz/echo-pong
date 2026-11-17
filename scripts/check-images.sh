#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
cache_dir="${TRIVY_CACHE_DIR:-/tmp/echo-pong-trivy-cache}"
scan_dir=$(mktemp -d)
trap 'rm -rf "$scan_dir"' EXIT
for architecture in arm64 amd64; do
  image="echo-pong:local-${architecture}"
  docker build --platform "linux/${architecture}" -t "$image" .
  docker image save "$image" -o "$scan_dir/image.tar"
  trivy --cache-dir "$cache_dir" image --input "$scan_dir/image.tar" \
    --scanners vuln --severity HIGH,CRITICAL --exit-code 1
  rm "$scan_dir/image.tar"
done
docker tag echo-pong:local-arm64 echo-pong:local
