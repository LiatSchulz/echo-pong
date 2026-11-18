#!/usr/bin/env bash
# Build both release images and binary archives, then fail on HIGH/CRITICAL findings.
# No login or publication occurs here; publishing must reuse these scanned images.
set -euo pipefail
cd "$(dirname "$0")/.."
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
for architecture in amd64 arm64; do
  image="echo-pong:release-$architecture"
  docker build --platform "linux/$architecture" \
    --label "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY:?}" \
    --label "org.opencontainers.image.revision=${GITHUB_SHA:?}" \
    --tag "$image" .
  docker image save "$image" -o "$temporary/image.tar"
  trivy image --input "$temporary/image.tar" --scanners vuln \
    --severity HIGH,CRITICAL --exit-code 1
done
python3 scripts/check-container.py echo-pong:release-amd64
scripts/build-binaries.sh
for architecture in amd64 arm64; do
  mkdir "$temporary/$architecture"
  tar -xzf "build/echo-pong_linux_${architecture}.tar.gz" -C "$temporary/$architecture"
  trivy rootfs --scanners vuln --severity HIGH,CRITICAL --exit-code 1 "$temporary/$architecture"
done
