---
name: Keep Kubernetes recovery material independent of the cluster
status: accepted
---

# Keep Kubernetes Recovery Material Independent of the Cluster

## Context

The single RKE2 server is a recovery-sensitive failure point. Its snapshots need
both an off-node destination and the corresponding server token. Recovery must
not depend on the failed Kubernetes cluster; external OpenBao and RustFS are
accepted dependencies.

## Decision

Send etcd snapshots to a dedicated per-cluster bucket on existing RustFS every six hours and
retain them for fourteen days, using verified HTTPS and a dedicated bucket-scoped
credential. Store that credential and the RKE2 server token in external OpenBao,
with separately protected operator recovery copies in Proton Pass.

Keep secret values out of Git, OpenTofu state/plans, cloud-init, logs and tickets.
Use an explicitly reviewed out-of-band enrollment boundary and preserve the
token material associated with retained recovery points.

## Consequences

- Approximately four hours is the initial control-plane recovery planning
  target, not an SLA or a measured restore time.
- Off-node snapshots are not off-site backups or backups of application volumes.
  Bucket scope, retention, freshness and isolated restore require verification.
- Automatic recovery obtains its token, identity and application credentials from
  external OpenBao and snapshots from RustFS. Dependency outages block recovery
  safely until those services return; a local-only restore route is not required.
- Independent token/credential copies protect custody, not a promise that the
  maintained recovery workflow runs without OpenBao or RustFS. An in-cluster secret
  controller would still create an unacceptable circular dependency.
- Notification platform, destination and thresholds remain undecided; scheduled
  snapshots alone do not establish successful backups or active monitoring.
