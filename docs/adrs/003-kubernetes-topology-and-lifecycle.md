---
name: Start Kubernetes with one control plane and dedicated workers
status: accepted
---

# Start Kubernetes With One Control Plane and Dedicated Workers

## Context

The homelab has two x86 Proxmox hosts with different CPU vendors. An initial
high-availability control plane would add operational complexity without three
independent physical failure domains.

## Decision

Start with one Rocky Linux 10 amd64 RKE2 server with colocated etcd on `compute`,
and one dedicated worker on each of `compute` and `store`. Install pinned RKE2
packages through persistent, signature-checked EL10 RPM repositories rather than
executing a remote installation script.

Give the API a stable private DNS identity and certificate coverage from initial
bootstrap. Preserve RKE2's supported sequential expansion to three server/etcd
members behind an independent API/registration frontend; do not use workload
service announcements as the future control-plane frontend.

## Consequences

- Control-plane downtime is accepted. API loss stops scheduling and reconciliation;
  surviving workers do not guarantee application or service-address availability.
- Ordinary applications are excluded from the control-plane node. Initial sizes
  are 2 vCPU / 4 GiB / 32-GiB OS disk for the server and 4 vCPU / 8 GiB /
  64-GiB OS disk for each worker.
- Worker VMs stay on their intended hosts; use pod recreation instead of
  cross-vendor live migration.
- Adding servers later must preserve the API identity, recovery material and
  existing datastore. A permanent two-member etcd cluster is not fault tolerant.
- This is an approved design, not a claim of production deployment or tested HA.
