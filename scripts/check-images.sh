#!/usr/bin/env bash
# Build ARM64 and AMD64 images and scan each for HIGH/CRITICAL vulnerabilities.
# Tag the Docker engine’s native architecture for local use after both scans pass.
set -euo pipefail
cd "$(dirname "$0")/.."
cache_dir="${TRIVY_CACHE_DIR:-/tmp/echo-pong-trivy-cache}"
case "$(docker info --format '{{.Architecture}}')" in
  aarch64|arm64) native_arch=arm64 ;;
  x86_64|amd64) native_arch=amd64 ;;
  *) echo 'Unsupported Docker engine architecture' >&2; exit 1 ;;
esac
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
docker tag "echo-pong:local-$native_arch" echo-pong:local
