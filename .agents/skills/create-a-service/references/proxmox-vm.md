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
- Treat template ID, target datastore, bridge, cloud user, and SSH keys as
  environment inputs. Do not assume a datastore name is valid on both nodes.

## VM Gate

Use `proxmox_virtual_environment_vm` and normally:

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

## Cloud-Init Gate

When package or application provisioning is needed:

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
