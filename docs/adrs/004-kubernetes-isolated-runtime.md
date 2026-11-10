---
name: Use stock Kata and Cloud Hypervisor for explicit isolated workloads
status: accepted
---

# Use Stock Kata and Cloud Hypervisor for Explicit Isolated Workloads

## Context

The cluster needs both ordinary containers and a stronger VM-backed workload
boundary. Stock Firecracker failed the SELinux-enforcing integration proof;
an experimental repair would require maintaining a custom runtime build.

## Decision

Keep `runc` as the default and select stock Kata Containers with Cloud Hypervisor
through the Rust `clh-runtime-rs` handler using an explicit RuntimeClass.
Keep SELinux enforcing, require usable nested KVM on eligible workers, and fail
observably rather than falling back when the isolated handler is unavailable.

Cloud Hypervisor was selected over Firecracker's custom-build path and
Dragonball's embedded VMM because stock deployment worked on both CPU vendors
and its separate VMM showed pod-specific SELinux confinement and seccomp.

## Consequences

- Use the stock overlayfs/virtio-fs path; Firecracker jailer/devmapper storage is
  not part of this design.
- Runtime labels/capability scheduling must prevent placement on unqualified
  workers. Upgrades require requalification of the named handler and its payload.
- Distinct VMM process labels do not prove full host-resource isolation. Runtime
  API/virtio-fs socket MCS separation and undrained shutdown remain qualification
  gaps; selecting the runtime does not accept those gaps as resolved.
- This boundary is stronger than ordinary container execution, not a complete
  security certification or permission to host mutually hostile tenants.
