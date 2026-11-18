#!/usr/bin/env bash
# Refuse existing versions, push the already-scanned local images, and publish binaries.
# Requires repository-scoped GH_TOKEN and the prepared release images/archives.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_REPOSITORY_OWNER:?}" "${GITHUB_SHA:?}" "${VERSION:?}"
[[ "$VERSION" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
repository="ghcr.io/${GITHUB_REPOSITORY,,}"
package="${GITHUB_REPOSITORY##*/}"
temporary=$(mktemp -d)
trap 'docker logout ghcr.io >/dev/null 2>&1; rm -rf "$temporary"' EXIT

# API 404 means absent. Authentication, network, and other errors fail closed.
if gh api "repos/$GITHUB_REPOSITORY/releases/tags/$VERSION" > /dev/null 2> "$temporary/error"; then
  echo "Release $VERSION already exists; refusing overwrite" >&2
  exit 1
elif ! grep -q 'HTTP 404' "$temporary/error"; then
  cat "$temporary/error" >&2
  exit 1
fi
if ! gh api --paginate "users/$GITHUB_REPOSITORY_OWNER/packages/container/$package/versions" \
    --jq '.[].metadata.container.tags[]' > "$temporary/tags" 2> "$temporary/error"; then
  if ! grep -q 'HTTP 404' "$temporary/error"; then
    cat "$temporary/error" >&2
    exit 1
  fi
fi
for tag in "$VERSION" "$VERSION-amd64" "$VERSION-arm64"; do
  if grep -Fxq "$tag" "$temporary/tags"; then
    echo "Registry tag $tag already exists; refusing overwrite" >&2
    exit 1
  fi
done
printf '%s' "$GH_TOKEN" | docker login ghcr.io --username "$GITHUB_REPOSITORY_OWNER" --password-stdin
for architecture in amd64 arm64; do
  docker tag "echo-pong:release-$architecture" "$repository:$VERSION-$architecture"
  docker push "$repository:$VERSION-$architecture"
done
docker buildx imagetools create --tag "$repository:$VERSION" \
  "$repository:$VERSION-amd64" "$repository:$VERSION-arm64"
docker buildx imagetools inspect "$repository:$VERSION" | tee "$temporary/index"
digest=$(awk '$1 == "Digest:" {print $2; exit}' "$temporary/index")
[[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]
printf '%s\n' "Image: $repository@$digest" > build/image-digest.txt
cat > "$temporary/notes" <<EOF
Linux AMD64 and ARM64 images and binaries passed HIGH/CRITICAL vulnerability gates.

Container: \`$repository:$VERSION\`
Immutable multi-platform image: \`$repository@$digest\`

Verify downloaded binary archives with \`sha256sum --check checksums.txt\`.
EOF
gh release create "$VERSION" --repo "$GITHUB_REPOSITORY" --verify-tag \
  --title "$VERSION" --notes-file "$temporary/notes" \
  build/echo-pong_linux_amd64.tar.gz build/echo-pong_linux_arm64.tar.gz \
  build/checksums.txt build/image-digest.txt
