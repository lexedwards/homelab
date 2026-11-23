---
name: Delegate snapshot lifecycle to native RKE2
status: accepted
---

# Delegate Snapshot Lifecycle to Native RKE2

## Context

RKE2 already implements scheduled snapshots, S3 upload, count-based retention and
native restoration. A separate timer and age-pruning wrapper duplicate its
operational responsibilities and must be installed again after replacing a host.

## Decision

Use native RKE2 scheduling and configurable local/S3 retention counts. Keep only
the integration for external OpenBao access, independent server-token custody,
safe replacement bootstrap and separate kubeconfig publication. This supersedes
the age-based retention choice in [the versioned recovery-window decision][previous]
and the scheduling/retention portion of [the custody decision][custody].

## Consequences

- Retention is a count, not a guaranteed age window. Logical deletion in a versioned
  bucket still does not mean permanent erasure or authorize version purge.
- Normal snapshots can use RKE2's native Kubernetes S3 Secret. Recovery cannot:
  the API is unavailable, so its credentials and original matching server token
  must remain recoverable from external OpenBao and independent custody.
- A snapshot does not supply its own decryption token. Preserve actual historical
  tokens while their snapshots or versions remain retained; never rotate a token
  merely to enable scheduling.
- Integration verification covers configuration, credentials, real off-node
  upload/retrieval and same-cluster recovery, not a reimplementation of RKE2's
  scheduling, pruning or datastore restoration behavior.

[previous]: 009-versioned-backup-recovery-window.md
[custody]: 007-kubernetes-recovery-custody.md
