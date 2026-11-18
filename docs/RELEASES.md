# Versioned releases

Images are stored under the `LiatSchulz` GitHub account at
`ghcr.io/liatschulz/echo-pong`. Public visibility simplifies reviewer pulls without
credential setup. The source repository is already public. A proprietary product
would normally restrict package access and provision read-only pull credentials.
Public access permits downloads; publishing still requires authorization.

The workflow is implemented; first tagged execution and public pull verification
remain pending until the reviewed change is merged.

## Release contract

- Versions use `vMAJOR.MINOR.PATCH`, starting with `v0.1.0`.
- Tagged source must belong to `main`.
- CI and disposable Kubernetes checks must pass before the publication job.
- Both platform images and binary outputs must pass vulnerability checks before
  production tags or release assets are published.
- The workflow pushes the same locally scanned images, then creates the combined
  AMD64/ARM64 index. It does not rebuild images after scanning.
- Version tags identify a release; deployments use immutable image digests.
- Existing release versions must not be overwritten.

## Distribution

The multi-platform index lets each node select Linux AMD64 or ARM64. A GitHub
Release contains binary archives, SHA256 checksums, and image-reference evidence.
The application token is provisioned separately at runtime and is never part of
the image or binary archive.

The registry stores image layers and metadata; it does not run the application.
Local Kubernetes still runs inside Colima. No AWS resources are required.

## Demo access

After successful publication and public package configuration:

```sh
docker pull ghcr.io/liatschulz/echo-pong:v0.1.0
```

[Validation evidence](../VALIDATION.md) records actual publication and deployment
results. Publishing a workflow is not itself proof that a release succeeded.

## Retention and cleanup

Keep the demonstrated release and the images needed for rollback. Do not delete
platform manifests referenced by a retained multi-platform index. Automated
retention and stale-version deletion are deferred; only temporary test resources
are removed as part of the demo workflow.

If a run partially publishes a version and then fails, existing tags are retained.
Investigate the failure and use a new version rather than silently replacing a
previously published artifact.
