#!/usr/bin/env bash
# Install fixed Linux security-tool releases after checking published SHA256 digests.
# Add the destination to subsequent GitHub Actions steps without registry access.
set -euo pipefail
destination="${1:?Usage: install-ci-tools.sh DESTINATION}"
mkdir -p "$destination"
destination=$(cd "$destination" && pwd)
[[ "$(uname -s)" == Linux ]] || { echo 'CI tool installer requires Linux' >&2; exit 1; }
case "$(uname -m)" in
  x86_64)
    trivy_archive=trivy_0.76.2_Linux-64bit.tar.gz
    trivy_sha=bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf
    gitleaks_archive=gitleaks_8.30.1_linux_x64.tar.gz
    gitleaks_sha=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
    ;;
  aarch64|arm64)
    trivy_archive=trivy_0.76.2_Linux-ARM64.tar.gz
    trivy_sha=ab9d51f86e6a5fb936f605faff6b593ac51bc378fff4d3e8b9d58358b9c367c3
    gitleaks_archive=gitleaks_8.30.1_linux_arm64.tar.gz
    gitleaks_sha=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080
    ;;
  *) echo 'Unsupported CI architecture' >&2; exit 1 ;;
esac
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
download() {
  local repository="$1" version="$2" archive="$3" checksum="$4" binary="$5"
  curl --fail --silent --show-error --location --retry 3 \
    "https://github.com/$repository/releases/download/$version/$archive" \
    -o "$temporary/$archive"
  printf '%s  %s\n' "$checksum" "$temporary/$archive" | sha256sum --check --strict
  tar -xzf "$temporary/$archive" -C "$destination" "$binary"
  chmod 0755 "$destination/$binary"
}
# Digests verified against the official repositories' release asset metadata.
download aquasecurity/trivy v0.76.2 "$trivy_archive" "$trivy_sha" trivy
download gitleaks/gitleaks v8.30.1 "$gitleaks_archive" "$gitleaks_sha" gitleaks
if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$destination" >> "$GITHUB_PATH"
fi
"$destination/trivy" --version
"$destination/gitleaks" version
