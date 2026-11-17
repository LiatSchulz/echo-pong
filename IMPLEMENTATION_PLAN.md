# Implementation plan

Infrastructure is the current priority. Application changes are limited to what is needed to operate and validate the deployment.

## Phase 1: infrastructure foundations

- Container: multi-stage, static Linux builds for amd64 and arm64; minimal non-root runtime; explicit build context exclusions.
- Kubernetes: two replicas, startup/readiness/liveness probes, rolling updates, disruption budget, resource sizing, restricted security context, mounted Secret, internal Service, ingress and network policy.
- Workstation: install and verify Go, a container runtime, kubectl, Kind, and security-scanning tools.
- Management: review the shared runtime contract and identify gaps before integration.

Runtime contract: port 8080; UID/GID 65532; executable `/ping-pong`; secret file `/var/run/secrets/echo-pong/token`. The runtime filesystem is read-only. Secrets are created outside version control. The Kubernetes secret volume must be readable by the non-root process.

## Phase 2: integrations and evidence

- Build and run the container; validate both architecture outputs.
- Check authenticated endpoints and failure cases, startup delay, non-root operation, and read-only filesystem compatibility.
- Deploy to a local cluster and test routing, secret permissions, network policies, readiness, and registry image access.
- Add graceful HTTP shutdown and bounded server timeouts as needed for safe termination.
- Exercise rolling updates under continuous requests; document the tested availability scope.
- Verify that the selected CNI enforces NetworkPolicy. A manifest accepted by the API is not evidence of traffic isolation.
- Distinguish local image loading from actual registry pulls; both need appropriate validation.

## Phase 3: CI/CD and releases

- Pull-request checks: Go checks, container builds, manifest validation, vulnerability and secret scanning.
- Tag-driven releases: amd64/arm64 binaries and checksums, both container platform scans, GHCR publication, GitHub Release assets.
- Gate production promotion on HIGH/CRITICAL vulnerability results; do not publish production tags before all platform gates pass.
- Use immutable image digests for deployments; make rollout and rollback reproducible.
- Document the deployment automation boundary: an ephemeral CI cluster validates deployment, while a persistent target requires explicit cluster access and configuration.
- Write the operational runbook: scaling, EKS, regional AWS image distribution, versioning, rollback, and cleanup that preserves deployed versions.
- Record real validation results and unresolved limitations. Do not claim unexecuted checks passed.

## Decisions to verify during integration

- Interpret “no direct internet access” as ingress/proxy-only incoming access plus denied application egress; confirm the implementation and document infrastructure exceptions.
- An ARM64 scheduling preference must allow an amd64-only local cluster to work.
- Ingress routing requires an installed controller; configuration alone does not supply one.
- Replica count and rolling-update settings do not guarantee availability through arbitrary node or cluster failures.
- A shell-free runtime requires lifecycle hooks that do not invoke a shell.
- Pin and verify tool/base-image versions against official sources at implementation time.
