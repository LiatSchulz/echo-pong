# Tomorrow's checklist

## Review the CI changes

- Review the next PR, workflow permissions, security gates, and actual Actions results.
- Check the updated [reviewer guide](START_HERE.md),
  [validation report](../VALIDATION.md), and [presentation](PRESENTATION.md).
- Address review feedback before merging.

## Decide registry visibility before publication

- Discuss public versus private GHCR packages. The GitHub source repository is
  currently public; package visibility is a separate decision.
- Decide who needs image access: reviewers, developers, and cluster nodes.
- For private images, agree how read-only pull credentials are provisioned and
  rotated without committing them or exposing them in workflow logs.
- Confirm the publication plan before adding GHCR authentication or push steps.

## Finish the release path after that decision

- Add version-tag validation and an explicit release dependency on all security checks.
- Publish the approved AMD64/ARM64 image index using immutable digests.
- Publish binary archives and checksums through GitHub Releases.
- Verify registry pulls using the chosen access model.
- Test a new-version rollout and rollback using published image digests.
- Document version retention and cleanup that preserves deployed and rollback images.
- Update the evidence table and presentation with real workflow and release links.

## Final review

- Start Colima with `colima start` before running workstation demos. CI uses its own cluster.

- Run the demo from the documented starting point.
- Review the EKS and regional image distribution explanations; no AWS provisioning.
- Confirm every requirement has an implementation reference and honest validation status.
- Merge the final reviewed changes before notifying reviewers that work is complete.
