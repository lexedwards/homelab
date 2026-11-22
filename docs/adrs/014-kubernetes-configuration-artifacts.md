---
name: Separate Kubernetes configuration artifacts from recovery snapshots
status: accepted
---

# Separate Kubernetes Configuration Artifacts From Recovery Snapshots

## Context

An administrator needs a recoverable kubeconfig after control-plane replacement,
but a kubeconfig grants cluster administration and is not an etcd recovery point.
Sharing the backup bucket or its credentials would couple two different access
and retention boundaries.

## Decision

Keep snapshots exclusively in the backup bucket and publish the kubeconfig in a
separate private, encrypted, versioned configuration bucket for each cluster.
Use a stable friendly cluster name for both bucket names and `kubeconfig.yaml` for
the configuration object, with the stable API endpoint. Workstation operators provision
storage and authorization; hosts fetch a distinct exact-object application S3
credential from external OpenBao through trusted SSH AppRole introduction.

Use create-only publication with content-verified retries; a changed kubeconfig
requires an explicitly approved conditional refresh rather than automatic
replacement. Keep the snapshot's matching server token in its independent
[recovery custody][custody], without rotating it as part of VM replacement.

## Consequences

- Publisher access cannot read backups or manage buckets; administrator access
  must include actual configuration-object download, not only inventory access.
- Retained kubeconfig versions remain privileged credentials. Encryption and
  versioning do not revoke them or replace server-token custody.
- Certificate rotation can make a retained artifact stale. Refresh is an explicit
  operation, while recovery of the cluster remains independent of publication.
- Separate buckets, application credentials and enrollment records add lifecycle
  work but avoid delivering workstation operator authority to a host.
- Both bucket names and exact publisher scope exist before first boot. Namespace
  UID and CA remain identity evidence, not storage addresses. No wildcard
  publisher grant or post-creation authorization handoff is needed.

[custody]: 007-kubernetes-recovery-custody.md
