# Proxmox LXC

Read this reference only after selecting an unprivileged Proxmox LXC and proving
that the workload has an established declarative provisioning mechanism.

## Provisioning Gate

The image catalogue currently creates VM templates, not LXC templates. An LXC
requires a `vztmpl` artifact on its target node. Manage a pinned,
checksum-verified `proxmox_virtual_environment_download_file` in the service root
or use a separately established LXC catalogue. Never pass a VM template ID to
an LXC resource.

Proxmox LXC initialization does not provide the VM baseline's raw cloud-init
user-data path. For an application guest, demonstrate the selected template's
cloud-init integration or choose a VM. A prebuilt appliance or alternative
bootstrap requires an explicit platform decision, not an assumed exception.
Do not hide `pct exec`, `remote-exec`, or SSH scripts in OpenTofu to imitate
cloud-init. Infrastructure remains OpenTofu-owned.

## LXC Gate

Use `proxmox_virtual_environment_container` and normally:

- set `unprivileged = true`, `started = true`, `start_on_boot = true`, and
  `protection = true`;
- use a pinned, checksum-verified Debian 13 `vztmpl` on the target node;
- set `operating_system.template_file_id` and the matching OS type;
- configure explicit CPU cores, memory, swap, and a root disk;
- initialize hostname and SSH public keys without a password;
- use DHCP on a stable interface name with the required bridge and optional
  VLAN; and
- wait for a non-loopback address only when the provider can determine it
  reliably for the selected template and network.

Do not change to privileged mode to solve ownership or device access without
documenting the host-security impact and obtaining explicit user approval.

## Exception Gate

Add `features`, ID maps, device passthrough, and mount points one at a time. For
each exception, document:

- the workload requirement;
- the exposed host path, device, filesystem, or kernel surface;
- UID/GID behavior for an unprivileged container;
- node pinning and migration effects;
- backup inclusion; and
- replacement and restore behavior.

Do not enable nesting, FUSE, `keyctl`, `mknod`, extra mount types, ID maps,
device passthrough, or privileged mode merely for convenience. Prefer a managed
Proxmox volume over a host bind mount when the storage design permits it.

LXC troubleshooting should cover the selected template, service state, UID/GID
mapping, mounts, features, devices, and address-discovery assumptions.
