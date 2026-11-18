#!/usr/bin/env bash
# Cross-compile Linux AMD64/ARM64 binaries, package archives, and verify checksums.
# Build outputs stay local; this script does not publish releases or tags.
set -euo pipefail
cd "$(dirname "$0")/.."
output=build
mkdir -p "$output"
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
for architecture in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$architecture" \
    go build -mod=readonly -trimpath -buildvcs=false -ldflags='-s -w' \
    -o "$temporary/echo-pong" .
  tar -czf "$output/echo-pong_linux_${architecture}.tar.gz" -C "$temporary" echo-pong
done
cd "$output"
archives=(echo-pong_linux_amd64.tar.gz echo-pong_linux_arm64.tar.gz)
if command -v sha256sum >/dev/null; then
  sha256sum "${archives[@]}" > checksums.txt
  sha256sum --check checksums.txt
else
  shasum -a 256 "${archives[@]}" > checksums.txt
  shasum -a 256 --check checksums.txt
fi
