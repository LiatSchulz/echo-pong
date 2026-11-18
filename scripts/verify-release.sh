#!/usr/bin/env bash
# Verify public registry access, deploy an immutable release under traffic, then roll back.
# Use the existing Kind cluster and auth token; do not load a local release image.
set -euo pipefail
set +x
cd "$(dirname "$0")/.."
image=${1:?Usage: scripts/verify-release.sh ghcr.io/OWNER/IMAGE@sha256:DIGEST}
url=${2:-http://127.0.0.1:8080}
if [[ ! "$image" =~ ^ghcr\.io/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$ ]]; then
  echo 'Require a lowercase GHCR image pinned by its full sha256 digest.' >&2
  exit 2
fi
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
k() { kubectl --context kind-echo-pong -n echo-pong "$@"; }
k get deployment echo-pong -o json > "$state/before.json"
k get serviceaccount echo-pong -o json > "$state/account.json"

# A fresh Docker config supplies no stored registry credentials.
mkdir "$state/anonymous"
daemon_endpoint=${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}
docker --config "$state/anonymous" --host "$daemon_endpoint" pull "$image"

python3 - "$image" "$state" <<'PY'
import hashlib
import json
import pathlib
import re
import sys
import urllib.parse
import urllib.request

image, directory = sys.argv[1:]
state = pathlib.Path(directory)
match = re.fullmatch(r'ghcr\.io/([a-z0-9._/-]+)@(sha256:[a-f0-9]{64})', image)
if not match:
    raise SystemExit('Require lowercase ghcr.io/OWNER/IMAGE@sha256:<64 hex characters>')
repository, digest = match.groups()
for filename, spec in [('before.json', ('spec', 'template', 'spec')), ('account.json', ())]:
    value = json.loads((state / filename).read_text())
    for key in spec:
        value = value[key]
    if value.get('imagePullSecrets'):
        raise SystemExit('Remove registry credentials from test pod/service account before anonymous pull verification')
query = urllib.parse.urlencode({'service': 'ghcr.io', 'scope': f'repository:{repository}:pull'})
# This is an anonymous registry bearer token, not a user credential.
with urllib.request.urlopen('https://ghcr.io/token?' + query, timeout=30) as response:
    token = json.load(response)['token']
headers = {'Authorization': 'Bearer ' + token, 'Accept': ', '.join([
    'application/vnd.oci.image.index.v1+json',
    'application/vnd.docker.distribution.manifest.list.v2+json',
    'application/vnd.oci.image.manifest.v1+json',
    'application/vnd.docker.distribution.manifest.v2+json'])}
def manifest(reference):
    request = urllib.request.Request(f'https://ghcr.io/v2/{repository}/manifests/{reference}', headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read()
    if 'sha256:' + hashlib.sha256(body).hexdigest() != reference:
        raise SystemExit('Registry manifest does not match the requested immutable digest')
    return json.loads(body)
index = manifest(digest)
platforms = {}
for child in index.get('manifests', []):
    platform = child.get('platform', {})
    if platform.get('os') == 'linux' and platform.get('architecture') in ('arm64', 'amd64'):
        document = manifest(child['digest'])
        platforms[platform['architecture']] = [child['digest'], document['config']['digest']]
if set(platforms) != {'amd64', 'arm64'}:
    raise SystemExit('Release index must include Linux AMD64 and ARM64')
(state / 'platforms.json').write_text(json.dumps({'index': digest, 'platforms': platforms}))
print('PASS: anonymous GHCR manifest access; both architecture manifests match their digests')
PY

python3 scripts/check-rollout.py --url "$url" --image "$image"
k get pods -l app.kubernetes.io/name=echo-pong -o json > "$state/pods.json"
kubectl --context kind-echo-pong get nodes -o json > "$state/nodes.json"
python3 - "$image" "$state" <<'PY'
import json
import pathlib
import sys
image, directory = sys.argv[1:]
state = pathlib.Path(directory)
release = json.loads((state / 'platforms.json').read_text())
nodes = {node['metadata']['name']: node['status']['nodeInfo']['architecture']
         for node in json.loads((state / 'nodes.json').read_text())['items']}
pods = [pod for pod in json.loads((state / 'pods.json').read_text())['items']
        if not pod['metadata'].get('deletionTimestamp')]
if len(pods) < 2:
    raise SystemExit('Expected at least two release pods')
for pod in pods:
    container = next(c for c in pod['spec']['containers'] if c['name'] == 'echo-pong')
    status = next(c for c in pod['status']['containerStatuses'] if c['name'] == 'echo-pong')
    architecture = nodes[pod['spec']['nodeName']]
    accepted = [release['index'], *release['platforms'][architecture]]
    if (container['image'] != image or container['imagePullPolicy'] != 'Always'
            or not status['ready'] or not any(status['imageID'].endswith(d) for d in accepted)):
        raise SystemExit('Pod does not run the expected ready registry image with Always pull policy')
    print(f"PASS: {pod['metadata']['name']} runs published {architecture} release ({status['imageID']})")
PY

python3 scripts/check-rollout.py --url "$url" --rollback
k get deployment echo-pong -o json > "$state/after.json"
python3 - "$state" <<'PY'
import json
import pathlib
import sys
state = pathlib.Path(sys.argv[1])
def container(filename):
    deployment = json.loads((state / filename).read_text())
    return next(c for c in deployment['spec']['template']['spec']['containers'] if c['name'] == 'echo-pong')
before, after = container('before.json'), container('after.json')
if any(before.get(key) != after.get(key) for key in ['image', 'imagePullPolicy']):
    raise SystemExit('Rollback did not restore the prior image and pull policy')
print('PASS: rollback restored the prior image and pull policy without observed HTTP failures')
PY
