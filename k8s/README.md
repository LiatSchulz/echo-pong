# Kubernetes deployment

These assets use Kustomize built into `kubectl`. Run commands from the repository root.
Target Kubernetes 1.33 or newer with the `PodLifecycleSleepAction` feature enabled
(the default). The shell-free lifecycle sleep hook is executed by kubelet, so the
scratch container needs no shell or `sleep` executable.

## Layout

- `k8s/base/`: common deployment, ClusterIP service, dedicated service account,
  restricted namespace, disruption budget, and network policy.
- `k8s/overlays/local`: uses the locally loaded `echo-pong:local` image and never
  attempts a registry pull.
- `k8s/overlays/ingress`: adds an optional Traefik Ingress for
  `echo-pong.localhost`. It does not install the controller or provision TLS.

The base image `ghcr.io/liatschulz/echo-pong:unreleased` is a deliberate placeholder,
not an existing release. Release automation and digest substitution are a later
integration step. Do not deploy that placeholder to production.

## Secret provisioning

The application requires a Secret named `echo-pong-auth` containing a `token` key.
Create it outside Git. The following generates a local development token without
placing its value in command arguments or terminal output:

```sh
kubectl apply -f k8s/base/namespace.yaml
umask 077
mkdir -p secrets
openssl rand -hex 32 > secrets/token
kubectl -n echo-pong create secret generic echo-pong-auth --from-file=token=secrets/token
```

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

After the container runtime, kubectl, and a Kind cluster are installed:

```sh
docker build -t echo-pong:local .
kind load docker-image echo-pong:local --name echo-pong
kubectl kustomize k8s/overlays/local
kubectl apply -k k8s/overlays/local
kubectl -n echo-pong rollout status deployment/echo-pong --timeout=180s
kubectl -n echo-pong get pods -o wide
kubectl -n echo-pong port-forward service/echo-pong 8080:80
```

Use your actual Kind cluster name if it differs. For Minikube, use
`minikube image load echo-pong:local` instead of `kind load`.
In a separate terminal, `curl http://127.0.0.1:8080/health` should return 200 and
`curl -i http://127.0.0.1:8080/ping` should return 401. For an authenticated
request without putting the token in process arguments:

```sh
{ printf 'Authorization: Bearer '; tr -d '\n' < secrets/token; printf '\n'; } |
  curl --fail --header @- http://127.0.0.1:8080/ping
```

Port-forward is an authenticated administrative proxy for local smoke tests. It
does not validate ingress routing, Service load balancing, or NetworkPolicy
enforcement and is unsuitable for a rolling-availability test.

## Registry images

For a public GHCR package, nodes can pull anonymously. For a private package,
provision a `kubernetes.io/dockerconfigjson` Secret named `ghcr-pull` in the
`echo-pong` namespace using a credential with read-only package access; never
commit its value. Configure the dedicated service account before starting pods:

```sh
kubectl apply -f k8s/base/service-account.yaml -n echo-pong
kubectl patch serviceaccount echo-pong -n echo-pong --type=merge \
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
For a local image plus ingress, compose a separate environment overlay or add the
Ingress resource to the local overlay; the supplied overlays are alternatives.
Do not assume applying an Ingress installs a controller. Production should use
TLS and an appropriate hostname; this HTTP-only hostname is a local example.
If using another controller, change the Ingress class and NetworkPolicy selectors
together. Cluster-admin access and namespace-label changes must be restricted.

NetworkPolicy requires an enforcing CNI such as Cilium or Calico. A default Kind
cluster's networking must not be treated as proof of enforcement. Install and
validate an enforcing CNI during integration, then test allowed proxy traffic,
blocked traffic from another pod, and denied outbound traffic. A policy manifest
alone does not establish isolation.

## Availability and scaling

Two replicas and preferred hostname anti-affinity spread pods when nodes are
available, while permitting a single-node laptop cluster. ARM64 nodes are
preferred, not required. Requests are initial sizing estimates; measure under
load before tuning limits or enabling an HPA with a metrics server. Scale with
`kubectl -n echo-pong scale deployment echo-pong --replicas=3` for manual testing.

RollingUpdate allows one additional pod and zero unavailable replicas. New pods
receive up to 60 seconds for startup (including the intentional 10-second wait),
then must remain ready for five seconds before an old replica is replaced. The
cluster must have spare capacity for the extra pod. A failed new revision stalls
the rollout while old healthy replicas remain; the deployment deadline reports
failure and does not automatically roll back. Use `kubectl rollout undo` or
redeploy the prior approved digest after investigating.

The disruption budget retains one available replica during voluntary evictions;
it does not prevent node failure, and it does not control Deployment rollouts.
The 10-second preStop delay allows endpoint-routing updates before SIGTERM, with
a 40-second total termination grace budget. **The supplied application currently
does not handle SIGTERM or drain active HTTP requests.** Application shutdown
support and a continuous-traffic rollout test are still required before claiming
verified zero-downtime updates. Single-node testing cannot prove availability
through a node failure.

## Validation status

All three Kustomize entrypoints render successfully with kubectl 1.37.2; YAML
parsing and whitespace checks passed. Live API validation, secret-permission checks,
network-policy enforcement, ingress traffic, resource sizing, and rolling-update
availability must be exercised after the Mac tooling and cluster are ready.

References: [container lifecycle hooks](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/),
[network policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/),
[Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/).
