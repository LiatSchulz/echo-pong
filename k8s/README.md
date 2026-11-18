# Kubernetes deployment

These assets use Kustomize built into `kubectl`. Run commands from the repository root.
Target Kubernetes 1.33 or newer with the `PodLifecycleSleepAction` feature enabled
(the default). The shell-free lifecycle sleep hook is executed by kubelet, so the
scratch container needs no shell or `sleep` executable.

## Layout

- `k8s/base/`: common deployment, ClusterIP service, dedicated service account,
  restricted namespace, disruption budget, and network policy.
- `k8s/overlays/local`: uses the locally loaded `echo-pong:local` image, never
  attempts a registry pull, and includes the Traefik Ingress.
- `k8s/overlays/ingress`: adds an optional Traefik Ingress for
  `echo-pong.localhost`. It does not install the controller or provision TLS.

The base image is pinned to the scanned multi-platform `v0.1.0` release digest.
The local overlay replaces it with the locally loaded image. Registry deployments
use the base or ingress overlay; the package must be publicly pullable.
See [release details](../docs/RELEASES.md).

## Secret provisioning

The application requires a Secret named `echo-pong-auth` containing a `token` key.
Create it outside Git. The following generates a local development token without
placing its value in command arguments or terminal output. First create the
`kind-echo-pong` cluster using the local setup command below:

```sh
kubectl --context kind-echo-pong apply -f k8s/base/namespace.yaml
umask 077
mkdir -p secrets
if [ ! -e secrets/token ]; then
  openssl rand -hex 32 > secrets/token
fi
test -s secrets/token || { echo 'Existing secrets/token is empty; provision a token first.' >&2; exit 1; }
chmod 600 secrets/token
kubectl --context kind-echo-pong -n echo-pong create secret generic echo-pong-auth \
  --from-file=token=secrets/token --dry-run=client -o yaml |
  kubectl --context kind-echo-pong apply -f -
```

These commands preserve an existing local token and create or update the cluster
Secret to match it. If the cluster Secret previously held a different value,
restart the Deployment after updating it:
`kubectl --context kind-echo-pong -n echo-pong rollout restart deployment/echo-pong`.
The local token and the token loaded by running pods must match for authenticated
checks to pass. Updating the Secret alone does not reload the running application.

`secrets/` is already ignored by Git. Do not add token files or generated Secret
YAML to the repository. For production, provision this Secret through the
organization's secret manager and restrict namespace access. Kubernetes Secrets
need encryption at rest and appropriate RBAC at the cluster level.

The Secret mounts as a directory at `/var/run/secrets/echo-pong`; its token is
readable by group 65532 (`0440`, `fsGroup: 65532`). The application runs as UID/GID
65532, with a read-only root filesystem, all capabilities dropped, no privilege
escalation, runtime-default seccomp, and no mounted Kubernetes API credential.
The app reads the token only at startup: update the Secret and restart the
Deployment to rotate it. During rotation, old and new replicas may accept
different tokens; coordinate clients or add dual-token support if required.

## Local deployment

Install Docker CLI, Kind, kubectl, and Helm, and start the container runtime.
On this Mac, Colima supplies the Linux Docker engine. Create the local stack:

```sh
scripts/local-cluster.sh
```

The script creates a single-node Kind cluster named `echo-pong` with default CNI
disabled, installs pinned Calico 3.33.0 for actual NetworkPolicy enforcement, and
installs Traefik chart 42.4.0 with its supported image 3.7.18. The node image is pinned by digest
in `k8s/local/kind.yaml`. The one-node layout fits the development VM's 2 CPUs and
4 GiB RAM; it does not demonstrate node-level redundancy. Only loopback port 8080
is published. The script targets context `kind-echo-pong` explicitly and does not
delete an existing cluster. An existing cluster must have been created with the
same config; creating it with default CNI requires deliberate recreation first.

After provisioning the auth Secret as described above:

```sh
docker build -t echo-pong:local .
kind load docker-image echo-pong:local --name echo-pong
kubectl kustomize k8s/overlays/local
kubectl --context kind-echo-pong apply -k k8s/overlays/local
kubectl --context kind-echo-pong -n echo-pong rollout status deployment/echo-pong --timeout=180s
kubectl --context kind-echo-pong -n echo-pong get pods -o wide
curl --fail -H 'Host: echo-pong.localhost' http://127.0.0.1:8080/health
```

For the complete image-validation flow, run `scripts/check-images.sh` first,
then `python3 scripts/check-container.py`, before loading and deploying the image.
Once ready, run `python3 scripts/check-rollout.py --url http://127.0.0.1:8080` for
continuous HTTP availability during a rolling restart, followed by
`scripts/verify-network.sh`. These scripts are local integration checks, not
proof of availability during an infrastructure failure.

The local HTTP request travels through the published NodePort and Traefik to the
ClusterIP Service. `curl -i -H 'Host: echo-pong.localhost'
http://127.0.0.1:8080/ping` should return 401. For an authenticated
request without putting the token in process arguments:

```sh
{ printf 'Authorization: Bearer '; tr -d '\n' < secrets/token; printf '\n'; } |
  curl --fail --header @- -H 'Host: echo-pong.localhost' http://127.0.0.1:8080/ping
```

For troubleshooting, `kubectl --context kind-echo-pong -n echo-pong port-forward service/echo-pong 18080:80`
provides an authenticated administrative proxy on port 18080. It
does not validate ingress routing, Service load balancing, or NetworkPolicy
enforcement and is unsuitable for a rolling-availability test.

## Registry images

For a public GHCR package, nodes can pull anonymously. For a private package,
provision a `kubernetes.io/dockerconfigjson` Secret named `ghcr-pull` in the
`echo-pong` namespace using a credential with read-only package access; never
commit its value. Select the intended context explicitly, then configure the
dedicated service account before starting pods. This example uses the local
cluster; change `target_context` for another environment:

```sh
target_context=kind-echo-pong
kubectl --context "$target_context" apply -f k8s/base/service-account.yaml -n echo-pong
kubectl --context "$target_context" patch serviceaccount echo-pong -n echo-pong --type=merge \
  -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}'
```

For repeatable production deployment, put the secret **reference** in an
environment overlay's ServiceAccount patch; provision the credential separately.
Select the approved multi-architecture release by digest with a Kustomize `images`
entry (`name: ghcr.io/liatschulz/echo-pong`, `digest: sha256:...`). That digest
should identify the multi-platform index so each node pulls its own architecture.
Registry access is performed by the node, not the application pod, so pod egress
denial does not block image pulls. Nodes still require registry connectivity.

## Ingress and network boundaries

The application has no NodePort, LoadBalancer, host networking, or host port. Its
ClusterIP is reached through an ingress controller or administrative proxy.
The NetworkPolicy also denies all application egress because this app has no
outbound dependencies, including DNS. It allows TCP/8080 only from pods labeled
`app.kubernetes.io/name: traefik` in the `traefik` namespace. Both conditions must
match. Node-origin kubelet probes are allowed by Kubernetes NetworkPolicy rules.

For the optional ingress overlay, install a Traefik controller with an IngressClass
named `traefik` and those exact namespace/pod labels, configure a local route to
its entrypoint, then apply `k8s/overlays/ingress` with a real registry image digest.
The local overlay already includes this Ingress with the locally loaded image.
Do not assume applying an Ingress installs a controller. Production should use
TLS and an appropriate hostname; this HTTP-only hostname is a local example.
If using another controller, change the Ingress class and NetworkPolicy selectors
together. Cluster-admin access and namespace-label changes must be restricted.

NetworkPolicy requires an enforcing CNI such as Cilium or Calico. A default Kind
cluster's networking must not be treated as proof of enforcement. Install and
validate an enforcing CNI during integration. `scripts/local-cluster.sh` installs
Calico. Run `scripts/verify-network.sh` after the application is ready: it first
proves a foreign pod can reach the application under a temporary explicit allow
policy, removes that policy, and requires a timeout from the same pod. It also
tests denied egress from an ephemeral container sharing an actual application
pod's network namespace, against a destination verified reachable from a control
pod. The script cleans up its diagnostic namespace and temporary policy; the
terminated ephemeral container record remains until the app pod is replaced.
This requires debug/exec permissions and the diagnostic images to be pullable.
Allowed ingress is checked through the real Traefik endpoint above. A policy
manifest alone does not establish isolation.

## Availability and scaling

Two replicas and preferred hostname anti-affinity spread pods when nodes are
available, while permitting a single-node laptop cluster. ARM64 nodes are
preferred, not required. Requests are initial sizing estimates; measure under
load before tuning limits or enabling an HPA with a metrics server. Scale with
`kubectl --context kind-echo-pong -n echo-pong scale deployment echo-pong --replicas=3` for manual testing.

RollingUpdate allows one additional pod and zero unavailable replicas. New pods
receive up to 60 seconds for startup (including the intentional 10-second wait),
then must remain ready for five seconds before an old replica is replaced. The
cluster must have spare capacity for the extra pod. A failed new revision stalls
the rollout while old healthy replicas remain; the deployment deadline reports
failure and does not automatically roll back. For the local deployment, use
`kubectl --context kind-echo-pong -n echo-pong rollout undo deployment/echo-pong` or
redeploy the prior approved digest after investigating.

The disruption budget retains one available replica during voluntary evictions;
it does not prevent node failure, and it does not control Deployment rollouts.
The 10-second preStop delay allows endpoint-routing updates before SIGTERM, with
a 40-second total termination grace budget. The application handles SIGTERM and
allows up to 20 seconds for active HTTP requests to drain, leaving headroom after
the 10-second preStop delay. HTTP timeouts bound slow clients. A rolling-restart
test completed 1,106 authenticated requests through ingress with zero observed
failures; see [validation results](../VALIDATION.md). Single-node testing cannot
prove availability through a node failure.

## Validation status

All three Kustomize entrypoints render successfully with kubectl 1.37.2. A local
Kind 1.37 ARM64 cluster has Calico 3.33.0 and Traefik 3.7.18 installed. The network
verification script passed foreign-ingress denial with a same-client positive
control and actual application-pod egress denial with a reachable destination
control. See [validation results](../VALIDATION.md) for the complete integration results and limits.
Resource limits remain initial estimates requiring load testing.

References: [container lifecycle hooks](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/),
[network policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/),
[Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/),
[Calico on Kind](https://docs.tigera.io/calico/latest/getting-started/kubernetes/kind),
[Traefik setup](https://doc.traefik.io/traefik/setup/kubernetes/).
