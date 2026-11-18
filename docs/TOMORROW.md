# Final completion checklist

- [x] Review and merge CI PR #3.
- [x] Select public GHCR for simple reviewer access under `LiatSchulz`.
- [x] Choose first release version `v0.1.0`.
- [ ] Review and merge the versioned-release PR.
- [ ] Create `v0.1.0` from merged `main` and check all release gates.
- [ ] Confirm the GHCR package is public after initial creation.
- [ ] Verify anonymous image pulls, registry-backed deployment, and rollback.
- [ ] Check binary archives and SHA256 checksums in GitHub Releases.
- [ ] Record real release/run/digest evidence in validation and reviewer docs.
- [ ] Run the demo from its documented starting point.
- [ ] Merge final documentation before notifying reviewers that work is complete.

Only temporary resources required by validation are cleaned up. Retain the
release and rollback images; automated stale-version deletion is deferred.
EKS and regional distribution remain documented designs, without AWS provisioning.
