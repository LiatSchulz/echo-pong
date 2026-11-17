# Technical questions and answers

Current implementation details and production design considerations for Echo Pong.
Executed checks are recorded in [the validation report](../VALIDATION.md).
CI/CD, GHCR publication, binary releases, and AWS deployment remain planned.

## Containers and local architecture

**Why Colima and Kind?** Colima supplies a Linux VM and Docker engine on macOS.
Kind runs Kubernetes nodes as Docker containers, with containerd inside each node
running the pod containers. This provides a reproducible local environment
without paid cloud resources.

**Why a scratch image?** The Go binary is static, so it needs no shell, package
manager, or libc at runtime. The smaller runtime reduces unnecessary components.
Go standard-library vulnerabilities still apply and require scanning and updates.
Debugging uses separate diagnostic containers rather than tools in the app image.

**How are both architectures supported?** The builder runs natively and Go
cross-compiles Linux amd64 and arm64 with CGO disabled. Both images were built,
scanned, and smoke-tested. AMD64 execution used emulation; native AMD64 performance
has not been measured. A combined registry image index remains release work.

**Why pin the compiler image by digest?** A digest fixes the exact builder content
used for the build. Updates become deliberate changes followed by rebuilding and
rescanning, rather than a tag silently changing the compiler.

## Availability and application changes

**Why change the application?** Default signal termination can interrupt active
HTTP requests. SIGTERM/SIGINT handling now drains requests for up to 20 seconds.
HTTP timeouts are additional hardening against slow clients. Authentication,
endpoints, CLI behavior, and the intentional startup delay are preserved.

**Why three probes?** Startup probes allow the intentional startup delay before
liveness checks begin. Readiness controls eligibility for Service traffic.
Liveness detects an unresponsive server and can trigger a restart. All use the
existing health endpoint; there is no external dependency to distinguish today.

**Why is a preStop delay insufficient on its own?** The delay gives routing
updates time to propagate while the process still serves. Graceful shutdown then
allows existing requests to finish after SIGTERM. The 10-second delay and
20-second drain fit within the total 40-second termination budget.

**Does zero unavailable replicas guarantee zero downtime?** No. It constrains
rolling replacement, but readiness, routing propagation, graceful shutdown, spare
capacity, and infrastructure health also matter. One local rolling restart served
1,106 requests with zero observed failures; this is evidence for that scenario.

**What happens if a new version never becomes ready?** Existing healthy replicas
remain while the rollout stalls. The progress deadline reports failure; it does
not automatically roll back. Restoring the previous approved digest is the
production rollback direction; automated release rollback remains planned.

## Security and registry access

**What does “no direct internet access” mean here?** Application traffic enters
through the proxy, and the app has no public Service or outbound connectivity.
An alternative interpretation restricts incoming exposure while allowing outbound
API calls. This app has no outbound dependencies, so the stricter policy fits.

**How was network isolation verified?** Calico enforces the policy. The same
foreign client first reached the app under a temporary allow rule, then timed out
after it was removed. An ephemeral container sharing an actual app pod's network
namespace also timed out reaching a destination verified reachable by a control
pod. This provides stronger evidence than merely applying a policy manifest.

**How can images be pulled if app egress is blocked?** Node container runtimes
pull images; application NetworkPolicy governs pod traffic. Node registry
connectivity is separate. Current local images are loaded into Kind, so actual
GHCR pulls remain to be validated after publication.

**Why public GHCR rather than private?** Public images simplify developer access
and anonymous cluster pulls. Private images provide access control for proprietary
artifacts, but need read-only pull credentials and credential lifecycle management.
Neither option replaces vulnerability scanning or protects secrets baked into an
image; secrets must stay outside images in both cases.

**Where is the authentication token stored?** A Kubernetes Secret mounts a
read-only token file, readable by the non-root group. It is not committed or built
into an image. Secret rotation requires a restart because the app reads the file
at startup; overlapping replicas can briefly accept different tokens. Production
also requires cluster-level RBAC, encryption at rest, and secret provisioning.

## Scaling, cloud, and release lifecycle


**How would you scale?** The server is stateless, so add replicas behind the same
Service. Use measured resource requests and an HPA once metrics and a target load
are available, then provide node capacity through a node autoscaler. Prefer ARM64
and spread replicas across nodes and availability zones. The current preferences
allow both replicas on one laptop node; they do not provide node redundancy.

**What changes on EKS?** Keep the application image and most manifests. Provision
private worker nodes across availability zones, registry connectivity, suitable
cluster access/RBAC, secret management, and a CNI configured to enforce network
policies. Terminate TLS at a supported ingress/load-balancer boundary and update
the app's ingress policy to match that traffic path. Revalidate pod draining and
load-balancer health during rollouts. Assign IAM permissions to controllers that
need AWS APIs; this app itself currently needs none. This is a design discussion,
not provisioned infrastructure. See the [EKS security guide](https://docs.aws.amazon.com/eks/latest/best-practices/security.html)
and [workload identity guidance](https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html).

**How can teams around the world pull images quickly?** Keep GHCR as the required
release registry, then mirror approved images into regional private ECR
repositories close to consumers. ECR supports [cross-region replication](https://docs.aws.amazon.com/AmazonECR/latest/userguide/registry-settings-configure.html).
Copy from the approved GHCR digest into ECR before replication, verifying both
the index and platform manifests. An alternative is a regional
[ECR pull-through cache for GHCR](https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache.html),
which requires upstream credentials in AWS Secrets Manager and has a first-pull
cache miss. No AWS resources have been created.

**How do versions and cleanup work?** Use semantic release tags plus immutable
commit identifiers for traceability, and digests for deployment. Retain deployed
and rollback digests, their platform manifests, release binaries, and provenance.
Expire unreferenced development images and caches on a documented schedule.
Apply lifecycle policies separately to regional mirrors; coordinate deletions
with deployment inventory so cleanup cannot remove an image still needed by a
new node or rollback. Automated tagging, cleanup, and retention remain pending.

