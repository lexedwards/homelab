---
name: Use external TrueNAS NFS storage with retained volumes
status: accepted
---

# Use External TrueNAS NFS Storage With Retained Volumes

## Context

Application data must survive worker replacement without building a distributed
storage platform inside the initial three-VM cluster. Existing TrueNAS storage
is available outside the Kubernetes worker lifecycle.

## Decision

Use a dedicated TrueNAS dataset/NFS export and the NFS CSI driver, with `Retain`
as the reclaim policy. Restrict export clients to the workers, retain root-squash,
and use explicit workload UID/GID permissions rather than world-writable exports.

The operator accepted an unrestricted export-client list for the initial dedicated
share to allow flexible addresses. This is a deployment-specific exception, not a
new default: network-reachable AUTH_SYS clients can assert numeric identities.
Keep root-squash and explicit permissions, and preserve the accepted client-access
risk in rollout review. Upstream network changes are not implied.

## Consequences

- CSI normally creates per-PVC subdirectories, not per-PVC ZFS datasets. The
  approved initial dataset quota is 500 GiB in aggregate; PVC size requests do
  not establish individual capacity enforcement.
- A deleted claim leaves data for deliberate operator recovery or cleanup;
  replacement claims do not automatically reattach released data.
- Loss of `store` or TrueNAS makes its volumes unavailable. This is persistence,
  not storage HA, independent backup or database-consistency qualification.
- Production export paths, ACLs, mappings and quota/snapshot accounting need
  review before use. Synthetic NFS compatibility does not qualify those settings.
