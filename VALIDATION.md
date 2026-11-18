# Validation evidence

Executed on 2026-11-17 using an Apple Silicon Mac, Colima (2 CPUs, 4 GiB),
Docker, and a single-node ARM64 Kind cluster. No AWS resources were created.

| Check | Result |
|---|---|
| `go test -race ./...` | Passed, including real TCP request draining, shutdown deadline, incomplete request headers, authentication, and public health |
| `go vet ./...` | Passed |
| Linux ARM64 and AMD64 image builds | Passed using the digest-pinned Go 1.27.4 builder |
| Trivy 0.76.2 vulnerability gate | Both images passed with zero HIGH/CRITICAL findings; Go binary dependencies were detected |
| Restricted container smoke tests | Both platforms passed health, authentication, CLI, default non-root user, and clean SIGTERM exit with read-only root filesystem and dropped capabilities |
| Kubernetes configuration | All three Kustomize entrypoints rendered; local deployment accepted by the live API |
| Startup and secret access | Two replicas became ready with the intentional startup delay and mounted token under UID/GID 65532 |
| Ingress routing | HTTP reached the app through localhost NodePort mapping, Traefik, and ClusterIP Service |
| Rolling restart | 1,106 authenticated requests through ingress, zero observed failures while both replicas were replaced |
| Foreign-pod ingress denial | Same client reached `/health` under a temporary allow policy, then timed out after that policy was removed |
| Application egress denial | A diagnostic ephemeral container in an actual application pod's network namespace timed out reaching a sink independently verified reachable from a control pod |
| Whitespace and shell syntax | Passed |

AMD64 runtime checks used emulation on ARM64, rather than a native AMD64 host.
The tested cluster uses Kubernetes 1.37, Calico 3.33.0, and Traefik chart 42.4.0
with its supported image 3.7.18. The final Traefik version was checked for
successful ingress routing after chart/image alignment.

## Reproduce

Run from the repository root with the container engine running. The cluster script
requires Helm; image checks require Trivy, and HTTP checks use Python 3.

```sh
scripts/check-images.sh
python3 scripts/check-container.py echo-pong:local
python3 scripts/check-container.py echo-pong:local-amd64
scripts/local-cluster.sh
```

Provision the local authentication Secret using [the deployment instructions](k8s/README.md#secret-provisioning),
with kubectl targeting `kind-echo-pong`. Keep `secrets/token` locally for the
rollout test. Then:

```sh
kind load docker-image echo-pong:local --name echo-pong
kubectl --context kind-echo-pong apply -k k8s/overlays/local
kubectl --context kind-echo-pong -n echo-pong rollout status deployment/echo-pong --timeout=180s
python3 scripts/check-rollout.py --url http://127.0.0.1:8080
scripts/verify-network.sh
```

The rollout check restarts the local Deployment. The network check temporarily
allows a diagnostic namespace, then removes that allowance and deletes its test
namespace. It leaves a terminated ephemeral-container record until that app pod
is replaced. Both scripts explicitly target the local cluster.

## Limits and follow-up

- A passing scan is a point-in-time result. Re-scan both architectures before
  publishing and whenever the vulnerability database or toolchain changes.
- The traffic check measures one local rolling restart of the same image. It
  does not establish a general availability guarantee, a new-version upgrade,
  multi-node fault tolerance, or production load capacity.
- Resource requests and limits remain initial estimates. HPA, production TLS,
  observability, and cloud load-balancer readiness need environment-specific work.
- Images were loaded locally. GHCR publication, anonymous registry pulls,
  multi-platform index publication and binary releases are now verified in the release phase below.
  CI workflows passed hosted validation; evidence is recorded below. Public GHCR is approved for reviewer access; release execution is tracked below.
- Network denial tests cover specific paths with positive controls. The intended
  policy is no application egress and ingress only from the proxy; node-level
  image pulls remain outside application NetworkPolicy.
- The original README remains the requirements reference; the reviewer guide
  maps each requirement to implementation, evidence, and scope limitations.

## CI phase

[CI workflows](docs/CI.md) add Go, secret, image, binary-preparation, and disposable
Kind deployment checks. Registry login, image publication, artifact uploads,
version tags, and GitHub Releases are excluded. Hosted validation passed for revision `e5c326d`:

- [CI run](https://github.com/LiatSchulz/echo-pong/actions/runs/44103276431): Go
  formatting/vet/race tests, full-history Gitleaks scan, native AMD64 and ARM64
  image builds, Trivy gates, HTTP/CLI smoke tests, and binary archives/checksums passed.
- [Integration run](https://github.com/LiatSchulz/echo-pong/actions/runs/44103277116):
  all manifests rendered, server-side validation and deployment passed, ingress
  rolling restart served **1,585 requests with zero failures**, and ingress/egress
  policy checks passed with positive controls. The disposable cluster was removed.

Actionlint, ShellCheck, shell syntax, documentation-link checks, and local binary
build/checksum verification also passed. Native hosted AMD64 execution now
complements the earlier emulated workstation checks. New-version upgrades,
registry pulls were not part of that initial run; both pulls and publication
are verified in the release phase below.

## Release phase

[Release v0.1.0](https://github.com/LiatSchulz/echo-pong/releases/tag/v0.1.0)
was published from merged `main` revision `de7937b` by
[successful workflow 44335024546](https://github.com/LiatSchulz/echo-pong/actions/runs/44335024546).
All source, full-history secret, native-platform CI, and Kind integration gates passed.
The publication job scanned both actual release image archives and both binary
outputs before pushing the same scanned images. No HIGH/CRITICAL findings were reported.

The release contains Linux AMD64/ARM64 archives, `checksums.txt`, and `image-digest.txt`.
Both downloaded archives passed local SHA256 verification on 2026-11-18.

```text
ghcr.io/liatschulz/echo-pong@sha256:9808ef4a2c2b0451db33b6ccbcb6fdc4f935d2f803bf54c35ebe5bd43f59c2f0
```

Public access was verified without stored Docker credentials: anonymous pull
succeeded, and both architecture manifests were fetched anonymously and checked
against their SHA256 digests.

On the ARM64 Kind cluster, the Deployment was updated from its local image to the
published digest with `imagePullPolicy: Always` and no image-pull Secret. Both
ready pods reported the expected release image ID. Continuous ingress traffic
observed **1,067 requests and zero failures** during the update. Rollback then
served **1,013 requests with zero failures** and restored the prior image and
pull policy. These are local-to-published artifact transition tests; no application
logic change was introduced between the local baseline and this release.

The base Deployment now references the scanned release digest; the local overlay
still supports local image loading. The live demo was reconciled to the published
release after rollback validation. Production fault tolerance and load capacity
remain outside these checks.

## Final repository review

Compared tracked implementation and documentation against the original README
at commit `10630de`. The requirement matrix and explicit interpretation limits
are in [the reviewer guide](docs/START_HERE.md#requirement-scope).

Small operational fixes were validated on 2026-11-18:

- Repeating release verification with the same digest and `Always` policy creates
  its own rollout revision before undo. The regression test served 1,108 update
  requests and 1,090 rollback requests with zero observed failures, restoring the
  prior image and pull policy.
- Repeated secret provisioning preserved the existing local token and matched the
  cluster Secret on two consecutive runs. No token was printed or rotated.
- The two-platform image build/scan script passed and selected the native ARM64
  image for the local Docker engine. AMD64 selection is supported by the same
  explicit architecture mapping but was not rerun on a separate x86 workstation.
- Workflow linting, ShellCheck, shell/Python syntax, all Kustomize entrypoints,
  documentation links, and whitespace checks passed.

Completed planning/checklist files and empty directory placeholders were removed.
The application, original requirements text, and published v0.1.0 artifacts were
not changed by this cleanup.
