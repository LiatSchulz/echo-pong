# Local validation

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
  multi-platform index publication, and binary release execution remain unverified.
  CI workflows passed hosted validation; evidence is recorded below. Public GHCR is approved for reviewer access; release execution is tracked below.
- Network denial tests cover specific paths with positive controls. The intended
  policy is no application egress and ingress only from the proxy; node-level
  image pulls remain outside application NetworkPolicy.
- The original README remains the project requirements reference. The implementation
  plan tracks the remaining release work.

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
registry pulls, and release publication remain unverified.

## Release phase

The [tagged release workflow](.github/workflows/release.yml) and
[registry-backed deployment check](scripts/verify-release.sh) are implemented.
Static workflow and shell checks passed. The first tagged publication, public
package visibility, anonymous pulls, upgrade, and rollback still require execution.
