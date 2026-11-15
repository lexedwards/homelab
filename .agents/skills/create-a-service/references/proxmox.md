# Proxmox

Read this reference only after the main skill classifies the
service for Proxmox. Resolve placement and guest type before loading a guest
implementation reference.

## Read Current Evidence

1. Read `hosts/compute/README.md` and `hosts/store/README.md` for
   node boundaries and provider workflow.
2. Read `services/image-catalogue/` for curated VM image inputs, cloud-init-ready
   template defaults, explicit IDs, and current provider constraints.
3. Read `services/observability-warehouse/` for snippet upload, cross-node clone,
   address discovery and protection. Its collector/Grafana `cloud-init.tf` and
   templates demonstrate native APT, deferred writes and provider-composed MIME;
   the warehouse declares Compose with credential-gated activation and no secret
   values in first-boot data. Its optional SSH introduction hook is isolated from
   VM replacement; its access root owns authorization, not credential values.
   Its full-control VM resource is not the default for every new clone.
   `services/kubernetes/cloud-init.tf` demonstrates the Rocky/RKE2 alternative:
   native distribution packages and signed `yum_repos`, with a bounded explicit
   install command preserving RKE2 repository exclusions and reboot/token gates.
4. Inspect the schema of the provider version pinned by current roots before
   using an argument not present in those examples.

The repository does not yet establish a Proxmox LXC application-bootstrap
convention. Do not present an untested mechanism as a local pattern.

Cluster membership provides management membership, not service high
availability. Local disks, templates, bind mounts, and passed-through devices
can pin a guest to a node. Do not configure HA, replication, live migration, or
automatic failover without explicit intent and compatible storage and devices.

## Choose The Guest

Read [Proxmox VM](proxmox-vm.md) when the service needs a separate kernel,
stronger isolation, Docker, reliable cloud-init provisioning, unusual networking
or devices, a vendor VM appliance, or a lifecycle that may move between nodes.

Read [Proxmox LXC](proxmox-lxc.md) only when the service is a small native Linux
workload that can share the host kernel, needs no nested runtime, and has an
established declarative provisioning path. Choose a VM instead of weakening LXC
isolation for compatibility.

For a vendor appliance, verify its authoritative publisher, image type, pinned
version, checksum, update policy, import path, and supported guest configuration.
Do not apply Debian, cloud-init, QEMU guest-agent, or catalogue assumptions
unless the appliance supports them.

## Shared Proxmox Gates

### Provider Gate

- Use the pinned `bpg/proxmox` provider and OpenTofu constraints.
- Require an HTTPS `proxmox_endpoint`; allow `proxmox_insecure` with a default of
  `false`.
- Supply the API token only through `PROXMOX_VE_API_TOKEN`; do not declare a
  token variable.
- Add the provider SSH block only when node-side file upload requires it. Use
  the local SSH agent and a required PAM username; never use password-based
  Proxmox SSH authentication. Do not read private-key files into OpenTofu. These
  execution credentials must be available for saved-plan apply as well as plan;
  local validation does not prove API authorization or agent/key readiness.

### Resource Gate

- Restrict `node_name` to `compute` or `store`.
- Require an explicit, validated cluster-wide guest ID. Never derive one from
  list position or let the provider choose it.
- Set typed, validated CPU, memory, and disk inputs.
- Attach one enabled NIC to a required bridge. Validate VLAN as `null` or an
  integer from 1 through 4094.
- Use DHCP, start immediately and on host boot, and add startup ordering only
  for a real dependency. With `proxmox_cloned_vm`, verify every required setting
  absent from its schema is inherited from the template or choose the
  full-control VM resource.
- Set `protection = true` for a long-lived guest when the selected resource can
  manage it. When `proxmox_cloned_vm` cannot manage protection, verify that it
  is inherited from the source template or choose the full-control VM resource;
  do not imply that inherited or operator-managed protection is tracked by
  OpenTofu. Protection must be deliberately disabled before destroy and is not
  a backup.
- Use lowercase tags containing `iac` and the service identity.
- Expose discovered addresses only as sensitive outputs.

### Cluster Gate

- Treat a later `node_name` change as migration or replacement, not metadata.
- Do not enable VM migration behavior or mark LXC mounts shared without
  confirming storage semantics and intended operations.
- Record whether every disk or mount is destroyed, detached, backed up, or
  replicated with the guest.
- State that local OpenTofu state needs secure backup.
