---
name: Deliver workload secrets as files from external OpenBao
status: accepted
---

# Deliver Workload Secrets as Files From External OpenBao

## Context

The homelab already has an external secret manager. Workloads need scoped access
without intentionally copying their delivered values into Kubernetes Secrets.
The stock confined CSI provider's default host directory was not writable under
the installed SELinux policy.

## Decision

Use Secrets Store CSI Driver and the OpenBao CSI provider with verified HTTPS,
short-lived workload service-account tokens and namespace/service-account/path
scoping. Disable optional Kubernetes Secret synchronization rather than adopting
External Secrets Operator's synchronization model.

Keep the chart's provider socket paths and nonprivileged provider configuration.
For the initial homelab integration, apply a persistent `container_file_t:s0`
file-context override only to its dedicated host directory, reusing installed
container-data permissions rather than adding a broad allow rule.

## Consequences

- Mounted files avoid this integration's intentional Secret synchronization;
  other Kubernetes Secrets and sensitive etcd snapshots still exist.
- Shared container-data policy is not OpenBao-exclusive. A confined container
  given that host path may interact with or interfere with the socket, subject
  to Unix permissions. The operator accepted this bounded initial risk with
  restricted host mounts/privileged execution and scoped OpenBao roles.
- A dedicated provider policy is optional hardening, not an initial deployment
  prerequisite. This acceptance does not cover Kata's separate runtime sockets.
- The tested stock provider was nonprivileged but UID 0; the main CSI driver
  remained privileged. Do not equate nonprivileged with non-root.
- Sealing the backend blocks fresh mounts but does not revoke values already
  delivered. Rotation of files is not proof of application reload.
