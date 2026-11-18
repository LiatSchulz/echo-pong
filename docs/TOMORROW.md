# Final completion checklist

- [x] Review and merge CI PR #3.
- [x] Select public GHCR for simple reviewer access under `LiatSchulz`.
- [x] Choose first release version `v0.1.0`.
- [x] Review and merge the versioned-release PR.
- [x] Create `v0.1.0` from merged `main` and check all release gates.
- [x] Confirm the GHCR package is public after initial creation.
- [x] Verify anonymous image pulls, registry-backed deployment, and rollback.
- [x] Check binary archives and SHA256 checksums in GitHub Releases.
- [x] Record real release/run/digest evidence in validation and reviewer docs.
- [x] Run the demo from its documented starting point.
- [ ] Review and merge the final evidence PR before notifying reviewers that work is complete.

Only temporary resources required by validation are cleaned up. Retain the
release and rollback images; automated stale-version deletion is deferred.
EKS and regional distribution remain documented designs, without AWS provisioning.
