---
name: Discover bootstrap behavior from runtime evidence, outside VM assets
status: proposed
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
As with the warehouse, an apply-time hook owns verified-SSH introduction after
VM/DNS creation. Its access/host-key/retry inputs affect only enrollment, never
cloud-init. The issuer is ephemeral; matching credentials are reused on retry.

Name each cluster before deployment and provision its dedicated backup and
configuration buckets declaratively. Keep the actual Kubernetes UID and CA as
identity evidence rather than using an unpredictable UID for storage or access.

Preserve initialized local data first. Otherwise join a verified available
cluster, recover the newest valid matching backup with its independently protected
token and compatible inputs after the old server has been fenced, or create only
when both cluster history and backup inventory are confirmed absent. Uncertainty
or failed recovery stops startup rather than selecting a creation fallback.

## Consequences

- No operation-mode, snapshot-selection or fencing inputs feed the VM resource.
  Changes to installed software still deliberately change immutable VM assets.
- First creation records durable cluster identity with create-only authorization;
  a known cluster with missing backups cannot silently become a new cluster.
- Incomplete recovery evidence requires inspection before replay. A replacement
  may use a different Kubernetes Node name while preserving VM hostname, cluster
  identity, existing workers and stable endpoints.
- Endpoint failure alone is not fencing. Single-server ownership must be verified
  before replacement enrollment; future HA needs a separately qualified contract.
- All deployments remain canonical-`main` operations with existing state, distinct
  from feature-worktree edits and offline verification.
- Existing [recovery custody][custody], [credential introduction][enrollment] and
  [artifact separation][artifacts] decisions remain in force. Enrollment or local
  validation does not establish deployed recovery readiness.
- External OpenBao and RustFS are accepted recovery dependencies. Their outages
  block recovery without fallback to new-cluster creation or a local-only restore.

[custody]: 007-kubernetes-recovery-custody.md
[enrollment]: 011-ssh-approle-enrollment.md
[artifacts]: 014-kubernetes-configuration-artifacts.md
