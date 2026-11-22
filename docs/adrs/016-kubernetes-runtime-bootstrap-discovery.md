---
name: Discover bootstrap behavior from runtime evidence, outside VM assets
status: accepted
---

# Discover Bootstrap Behavior From Runtime Evidence, Outside VM Assets

## Context

Cloud-init changes replace the guest VM. Embedding lifecycle switches, selected
snapshots or enrollment metadata makes operational preparation itself propose a
replacement and adds unnecessary operator decisions to boot.

## Decision

Keep cloud-init as fixed installation assets and an enrollment-gated startup
procedure. Introduce OpenBao access over verified SSH separately; obtain runtime
configuration, existing identity and distinct application credentials from OpenBao.

Preserve initialized local data first. Otherwise join a verified available
cluster, recover the newest valid matching backup when the exclusive old server
has been fenced, or create only when both cluster history and backup inventory
are confirmed absent. Uncertainty stops startup rather than selecting a fallback.

## Consequences

- No operation-mode, snapshot-selection or fencing inputs feed the VM resource.
  Changes to installed software still deliberately change immutable VM assets.
- First creation records durable cluster identity with create-only authorization;
  a known cluster with missing backups cannot silently become a new cluster.
- Endpoint failure alone is not fencing. Single-server ownership must be verified
  before replacement enrollment; future HA needs a separately qualified contract.
- All deployments remain canonical-`main` operations with existing state, distinct
  from feature-worktree edits and offline verification.
