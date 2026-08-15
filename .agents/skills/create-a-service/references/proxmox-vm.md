# Proxmox VM

Read this reference after selecting a Proxmox VM.

## Image And Clone Gate

- Clone an existing reviewed catalogue template whose supported release and
  guest metadata fit the workload. Do not assume Debian 13 is available. If no
  compatible reviewed template exists, stop for an image-curation decision;
  never invent an unsupported catalogue entry or assume an unmanaged template.
- Require `template_vm_id`; require `template_node_name` when source and target
  nodes can differ.
- Use a full clone to the selected VM datastore with bounded clone retries.
- When cloning from `store` to `compute`, identify both nodes explicitly and
  confirm Proxmox can copy source disks to the target datastore. Cluster
  membership does not make node-local storage shared.
- Treat template ID, target datastore, and bridge as environment inputs. For the
  full-control resource, also treat cloud user and SSH keys as environment
  inputs. The cloned resource cannot manage those initialization settings; they
  must already be safely supplied by the template or the resource is unsuitable.
  Do not assume a datastore name is valid on both nodes.

## Choose The Clone Resource

Validate the exact resource name and schema against the pinned provider. With
the repository's current provider line, use `proxmox_cloned_vm`; do not
introduce the deprecated `proxmox_virtual_environment_cloned_vm` alias.

Prefer `proxmox_cloned_vm` when the template supplies the baseline and the
service needs explicit control only over configuration supported by that
resource. It is an opt-in manager: inherited configuration that is not declared
is preserved without being tracked, declared configuration is managed, and
removing a declaration stops managing it rather than deleting it. Network and
disk maps address stable Proxmox slots such as `net0` and `scsi0`, avoiding the
legacy resource's ordered-list ambiguity and inherited-configuration drift.
The [provider clone migration guide][clone-migration-guide] is the source for
these ownership semantics. Use the pinned provider schema, not the latest guide,
as the authority for exact resource names and attributes.

Use `proxmox_virtual_environment_vm` with a `clone` block when the service must
manage configuration absent from the pinned `proxmox_cloned_vm` schema. This
currently includes guest-specific cloud-init initialization, QEMU guest-agent
configuration and address waiting, BIOS or machine settings, boot order, EFI or
Secure Boot, TPM state, passthrough, serial devices, startup ordering, on-boot
behavior, and protection. The legacy clone path remains valid; do not select
`proxmox_cloned_vm` merely because it is newer when its opt-in subset cannot
express the required lifecycle.

## Cloned VM Gate

When using `proxmox_cloned_vm`:

- use `id` for the target guest ID and `clone = { source_vm_id = ... }`;
- use `source_node_name`, `target_datastore`, `full = true`, and bounded
  `retries` for a cross-node full clone;
- model NICs as a `network` map keyed by `netN`, using `tag` for a VLAN;
- model disks as a `disk` map keyed by their slot, using `size_gb` and never
  requesting a shrink;
- decide separately for every inherited device whether OpenTofu manages it,
  preserves it unmanaged, or removes it through the explicit `delete` map;
- remember that removing a device from `network` or `disk` relinquishes
  management but does not remove it from Proxmox; and
- keep `delete_unreferenced_disks_on_destroy = false` unless deleting every
  unmanaged inherited disk is explicitly intended and its data lifecycle is
  documented.

Treat all undeclared inherited settings as template-owned, not as enforced
service configuration. Verify the reviewed template actually carries every
required unmanaged setting.

## Full-Control VM Gate

When using `proxmox_virtual_environment_vm`, normally:

- enable the QEMU guest agent, install it in the guest, and wait for a
  non-loopback IPv4 address;
- enable trim when storage supports discard;
- set `started = true`, `on_boot = true`, and `protection = true`;
- use CPU type `host` unless migration compatibility requires a portable model;
- use `virtio-scsi-single`, a `scsi0` disk with discard and I/O threading, and a
  VirtIO NIC;
- preserve the template's UEFI, Q35, serial console, DHCP, and Secure Boot
  baseline unless the workload has a documented incompatibility; and
- set the guest operating-system type to Linux for Linux guests.

Its clone syntax remains `clone { vm_id = ... }`; network and disk devices
remain repeated blocks. Accept its management of inherited configuration and
the resulting drift behavior deliberately.

## Migration Gate

Changing an existing clone from `proxmox_virtual_environment_vm` to
`proxmox_cloned_vm` is a resource-model migration, not a safe rename. The normal
plan recreates the VM; a requested target ID can also prevent create-before-
destroy because the existing guest already owns it. Before authoring a
migration, establish downtime, durable-data export or restore, guest-ID
handling, protection handling, and rollback. Do not perform state removal or
import unless the user explicitly requests the migration operation and the
current state is backed up.

Map the configuration deliberately:

| Legacy VM clone | `proxmox_cloned_vm` |
| --- | --- |
| `vm_id` | `id` |
| `clone.vm_id` | `clone.source_vm_id` |
| `clone.node_name` | `clone.source_node_name` |
| `clone.datastore_id` | `clone.target_datastore` |
| `cpu` block | `cpu` attribute object |
| `memory` block | `memory` attribute object |
| `network_device` blocks | `network` map keyed by `netN` |
| `network_device.vlan_id` | `network.netN.tag` |
| `disk` blocks with `interface` | `disk` map keyed by the interface |
| `disk.size` | `disk.<slot>.size_gb` |
| `memory.dedicated` | `memory.size` |

For each legacy setting with no cloned-resource equivalent, decide whether it
is safely inherited from the source template or whether the migration must not
proceed. Importing the existing `node/id` into the new resource can avoid guest
recreation but changes which configuration OpenTofu owns; treat it as an
explicit state migration and inspect a refreshed saved plan before any apply.

## Cloud-Init Gate

When guest-specific package or application provisioning is needed, use the
full-control VM resource because `proxmox_cloned_vm` cannot manage cloud-init
initialization. Then:

- add `.yamllint`, `cloud-init/user-data.tftpl`, and `config/` for substantial
  service files;
- upload tracked raw cloud-init through a snippets-enabled datastore;
- add provider SSH only because `source_raw` requires node-side file upload;
- create a non-root administrator with validated SSH public keys;
- disable password login and root SSH login;
- install and enable `qemu-guest-agent`; and
- keep stable addressing outside the guest.

The snippet datastore may default to `local` only when that is the established
node convention. Changing cloud-init does not rerun first-boot setup on an
existing VM.

## Workload Gate

- Prefer a native package and systemd service.
- For Docker, use a VM rather than LXC. Write declarative Compose configuration,
  manage it with systemd, and apply the hardening in
  [Lifecycle And Operations](lifecycle-and-operations.md).
- Put bounded first-boot readiness in cloud-init when suitable. Do not make
  OpenTofu depend on an unbounded application wait or operator enrollment.

VM troubleshooting should cover cloud-init, the QEMU guest agent, the selected
template, snippet upload, and the local service readiness check.

[clone-migration-guide]: https://registry.terraform.io/providers/bpg/proxmox/latest/docs/guides/migration-vm-clone
