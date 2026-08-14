---
name: create-proxmox-service
description: Creates or changes Proxmox VM and LXC service roots using OpenTofu on the compute and store cluster. Use when adding a Proxmox-hosted service, virtual machine, container, appliance, systemd workload, or Docker Compose workload under services/.
---

# Create A Proxmox Service

Create a self-contained OpenTofu root under `services/<service-name>/`. Follow
the repository's current Proxmox conventions while keeping cluster bootstrap,
image curation, guest creation, and application lifecycle explicit.

## Non-Negotiable Rules

- Use OpenTofu. Do not introduce another IaC tool or describe the configuration
  as Terraform, except where an ecosystem filename such as
  `terraform.tfvars` is unavoidable.
- Target only the `compute` or `store` node unless the user changes the cluster
  topology.
- Treat VM IDs as cluster-wide identifiers. Require an explicit, validated ID;
  never derive one from list position or let the provider choose it.
- Prefer Debian 13 unless the workload or appliance requires another operating
  system.
- Prefer a Linux-native package and systemd service over a container runtime.
  If a container runtime is justified, use Docker Compose rather than an
  imperative `docker run` workflow.
- Default to an unprivileged LXC. Do not enable LXC nesting, FUSE, `keyctl`,
  `mknod`, extra mount types, ID maps, device passthrough, or privileged mode
  unless the workload requires the specific exception.
- Protect long-lived guests against accidental deletion with the Proxmox
  `protection` flag. Explain that protection is not a backup and must be
  disabled deliberately before a planned destroy.
- Never apply infrastructure unless the user explicitly asks for an apply.

## Protect Local Infrastructure Data

Treat all environment-specific network, storage, identity, and credential data
as private, even when it may not conventionally be called a secret.

- Never disclose, commit, default, or document real IP addresses, CIDRs,
  gateways, DNS servers, VLAN IDs, API endpoints, storage endpoints, tokens,
  passwords, private keys, or application credentials.
- Represent required environment data as typed OpenTofu variables with no
  defaults. Values belong only in ignored local variable files, `TF_VAR_...`
  environment variables, or an approved secret store.
- Do not read ignored `terraform.tfvars`, state, saved plans, rendered
  cloud-init data, or other local files to discover values. Do not reproduce
  values from command output in chat, documentation, tests, commit messages, or
  pull requests.
- A tracked `terraform.tfvars.example` may name required variables and explain
  where values belong, but must not assign plausible network, storage,
  identity, or credential values. Use commented assignments without values.
- Use semantic placeholders in commands and prose, such as
  `<proxmox-endpoint>`, `<service-address>`, and `<datastore-id>`. Loopback
  addresses are acceptable for in-guest health checks.
- Supply the Proxmox API token only through `PROXMOX_VE_API_TOKEN`. Use a
  least-privilege token and do not declare a token variable.
- Mark address and credential outputs or variables `sensitive = true` where
  OpenTofu supports it. Explain that this redacts normal CLI output but does not
  encrypt local state.
- Keep application credentials out of OpenTofu state and cloud-init snippets.
  Prefer post-deployment enrollment with a root-owned environment or credential
  file. If first boot cannot work without a secret, explain the state exposure
  and obtain the user's decision before implementing it.

Before finishing, inspect only the tracked diff and remove any environment
value that escaped into it.

## Establish The Workload

Infer details from the request and tracked repository files where possible. Ask
a concise question only when a missing choice blocks a safe implementation.
Establish:

- service name, purpose, and upstream installation guidance;
- VM, unprivileged LXC, or a vendor appliance, including why that boundary fits;
- target node and the workload reason for its placement;
- source image or template, version, publisher checksum, and update policy;
- ports, protocols, intended callers, and outbound dependencies;
- CPU, memory, swap, disk, and hardware acceleration requirements;
- persistent paths, storage locality, replacement consequences, and backup
  expectations;
- deterministic local readiness checks;
- startup and shutdown dependencies; and
- operator-managed enrollment or configuration after deployment.

Do not silently invent exposure, persistence, privilege, passthrough,
authentication, migration, or high-availability requirements.

## Read Current References

Use current tracked files rather than stale copied snippets. Do not open ignored
runtime, variable, plan, or state files.

1. Read `hosts/compute/README.md` and `hosts/store/README.md` for the current
   node boundaries and provider workflow.
2. Read `services/image-catalogue/` for curated VM image inputs, cloud-init-ready
   VM template defaults, explicit IDs, and the current provider constraint.
3. Read `services/observability-warehouse/` for the end-to-end VM baseline,
   raw cloud-init snippet upload, clone workflow, guest-agent address wait,
   deletion protection, saved plans, YAML validation, and credential enrollment.
4. Inspect the schema of the provider version pinned by current roots before
   using a resource or argument not present in those examples. Do not guess from
   a newer provider release.

The repository currently has no tracked Proxmox LXC service. Treat the LXC
guidance in this skill as the baseline and validate every selected provider
argument against the pinned provider schema. Do not present an untested LXC
application bootstrap mechanism as a local convention.

If references conflict, follow this skill's security and data-protection rules,
then use the most recent common pattern. Never copy a concrete environment value
from an existing example.

## Choose Placement

Use workload needs, not spare capacity alone, to select the node:

- Prefer `compute` for CPU-bound work, general compute, and workloads coupled to
  its GPU or other local devices.
- Prefer `store` for persisted-data-intensive and storage-coupled workloads.
- Confirm the selected node has the required bridge, datastore content types,
  disk capacity, template access, and physical devices.

The two nodes are in one Proxmox datacenter cluster, but cluster membership does
not make a service highly available. Local disks, local templates, bind mounts,
and passed-through devices can pin a guest to one node. Do not configure HA,
replication, live migration, or automatic failover unless the user requests it
and the storage and device design supports it.

For a VM cloned from the image catalogue on `store` to `compute`, identify the
source node explicitly in the clone block and the target node on the VM. Use a
full clone. Confirm Proxmox can copy the selected source disks to the target
datastore; do not assume that cluster membership makes node-local storage
shared. Review any later `node_name` change as a migration or replacement, not
as a harmless metadata update.

## Choose VM Or LXC

Prefer a VM when the service needs:

- a separate kernel or stronger isolation from the Proxmox host;
- Docker or another nested container workload;
- reliable cloud-init first-boot application provisioning;
- kernel modules, unusual networking, or broad device access;
- a vendor appliance image; or
- a lifecycle that may later move between cluster nodes.

Prefer an unprivileged LXC when the service is a small Linux-native workload,
can share the Proxmox kernel, needs no nested container runtime, and has a clear
declarative installation path. Choose a VM instead of weakening LXC isolation
to make an incompatible workload run.

The image catalogue currently creates VM templates only. An LXC requires a
`vztmpl` OS template file available on its target node. Either manage a pinned,
checksum-verified `proxmox_virtual_environment_download_file` in the service
root or establish a separately managed LXC catalogue. Do not pass a VM template
ID to an LXC resource.

Proxmox LXC initialization does not provide the raw cloud-init user-data pattern
used by the warehouse VM. Use LXC for an infrastructure-only guest, a reviewed
prebuilt appliance/template, or a workload with an explicitly agreed
configuration-management path. Do not hide `pct exec`, `remote-exec`, or SSH
scripts in OpenTofu to imitate cloud-init. If repeatable first-boot application
provisioning is required and no LXC mechanism has been established, use a VM or
ask the user to choose the lifecycle boundary.

## Create The Service Root

Normally create:

```text
services/<service-name>/
|-- Makefile
|-- README.md
|-- main.tf
|-- terraform.tfvars.example
|-- variables.tf
`-- versions.tf
```

For VM cloud-init, also create `.yamllint` and
`cloud-init/user-data.tftpl`. Put substantial service files under `config/` and
encode their rendered content into cloud-init rather than constructing YAML in
shell commands.

Generate `.terraform.lock.hcl` with `tofu init`; do not hand-write it. Rely on
the repository root's local-state, saved-plan, override, and local-variable
ignore rules. Use the reference roots' Makefile workflow: `init`, `fmt`,
`fmt-check`, `tofu-validate`, `validate`, `plan`, and saved-plan-only `apply`.
Add `yaml-validate` when the root tracks YAML or cloud-init templates.

Use names derived consistently from the kebab-case service directory: kebab
case for the Proxmox guest name and snake case for OpenTofu labels. Add concise
Proxmox descriptions and lowercase tags that include `iac` and the service
identity.

## Implement The Shared Baseline

Unless the service has a documented reason to differ, both guest types must:

- use the `bpg/proxmox` provider and OpenTofu versions pinned by current roots;
- configure the provider from a required HTTPS `proxmox_endpoint` and the
  optional `proxmox_insecure` flag, which defaults to `false`;
- use an explicit `node_name` restricted to `compute` or `store` and an explicit
  cluster-wide `vm_id` in the valid Proxmox range;
- set workload-appropriate CPU, memory, and disk allocations through typed,
  validated variables;
- attach one enabled network interface to a required non-empty bridge, with an
  optional VLAN ID validated as `null` or an integer from 1 through 4094;
- use DHCP by default and keep stable addressing in upstream DHCP and DNS;
- start immediately and on host boot;
- set `protection = true` for a long-lived service;
- use an explicit startup order only when a real dependency requires it; and
- expose discovered addresses only as sensitive outputs.

Do not add the provider's SSH block unless a resource needs node-side file
upload. `proxmox_virtual_environment_file.source_raw` requires SSH access in
addition to the API token; use the local SSH agent and a required PAM username,
as in the warehouse root. Never add password-based Proxmox SSH authentication.

## Implement A VM

Use `proxmox_virtual_environment_vm` and normally:

- clone a reviewed Debian 13 template managed by `services/image-catalogue/`;
- require `template_vm_id`; add `template_node_name` when source and target nodes
  can differ;
- use a full clone to the selected VM datastore, with bounded clone retries;
- enable the QEMU guest agent, install it in the guest, enable trim when the
  storage supports discard, and wait for a non-loopback IPv4 address;
- set `started = true`, `on_boot = true`, and `protection = true`;
- use CPU type `host` unless migration compatibility requires a portable model;
- use `virtio-scsi-single`, a `scsi0` disk with discard and I/O threading, and a
  VirtIO network device;
- keep the template's UEFI, Q35, serial console, DHCP, and Secure Boot baseline
  unless the workload has a documented incompatibility;
- set the guest operating system type to Linux for Linux guests; and
- upload tracked raw cloud-init through a snippets-enabled datastore when
  package and application provisioning is needed.

Cloud-init must create a non-root administrative user with one or more
validated SSH public keys, disable password and root SSH login, install and
enable `qemu-guest-agent`, and provision the selected native systemd or Compose
workload. Keep stable addressing outside the guest.

The template ID, target datastore, bridge, cloud user, and SSH public keys are
environment-specific inputs. The snippet datastore may default to `local` only
when that is the established node convention. Do not assume a datastore name is
valid on both nodes.

## Implement An LXC

Use `proxmox_virtual_environment_container` and normally:

- set `unprivileged = true`, `started = true`, `start_on_boot = true`, and
  `protection = true`;
- use a pinned, checksum-verified Debian 13 `vztmpl` artifact on the target node;
- set `operating_system.template_file_id` from the managed or explicitly
  supplied template file ID and select the matching OS type;
- configure explicit CPU cores, dedicated memory, swap, and a root disk on the
  selected datastore;
- set initialization hostname, SSH public keys, and DHCP networking;
- define the primary `network_interface` with a stable interface name, required
  bridge, and optional VLAN ID; and
- wait for the required non-loopback address only when the provider can
  determine it reliably for the selected template and network.

Do not set an initialization password. Do not change `unprivileged` to `false`
to solve file ownership or device access without documenting the host-security
impact and obtaining the user's approval.

Add `features`, `idmap`, `device_passthrough`, or `mount_point` blocks one by one
for stated workload requirements. For each exception, document:

- why the service needs it;
- the host path, device, filesystem, or kernel surface it exposes;
- UID/GID ownership behavior for an unprivileged container;
- whether it pins the container to a node or blocks migration;
- whether it is included in Proxmox backups; and
- what happens during replacement and restore.

Never expose arbitrary host directories or devices for convenience. Prefer a
managed Proxmox volume over a bind mount for persistent service data when the
storage design permits it.

## Provision Safely

For a native deployment:

- Prefer distribution packages or a pinned, verified vendor repository.
- Install and enable one clear systemd unit.
- Harden authentication and listeners to the stated audience. Do not broaden
  access merely to simplify setup.
- Avoid piping a remote script into a shell. If no practical alternative
  exists, document that the installer is unpinned and review its source and
  transport before use.

For a justified Docker deployment in a VM:

- Install Docker and Compose from the chosen package source.
- Write a declarative `compose.yaml` and manage it with a systemd unit.
- Pin images to the narrowest maintainable version policy and document mutable
  tags.
- Drop container capabilities, set `no-new-privileges`, bound log growth, and
  publish only required ports where supported by the workload.
- Use Compose commands for upgrades, restarts, status, logs, and troubleshooting.

For both models, define a deterministic local readiness check. Cloud-init may
perform bounded first-boot checks, but do not make OpenTofu depend on an
unbounded application wait or on operator-managed credential enrollment.

## Handle Persistence, Replacement, And Cluster Behavior

- Separate replaceable system/configuration data from irreplaceable application
  data where the storage design supports it.
- Use Proxmox-managed disks or volumes for persistent data. Document whether
  each disk or LXC mount is destroyed, detached, backed up, or replicated with
  the guest.
- Keep bulk durable data in an appropriate storage service when that is the
  application's supported architecture; do not claim a live filesystem copy is
  an application-consistent backup.
- Require tested backups in another fault domain for important data. Proxmox
  protection, OpenTofu lifecycle rules, replication, and RAID are not backups.
- State that OpenTofu state is local and must be backed up securely.
- Explain that changing VM cloud-init updates the snippet but does not rerun
  first-boot setup on an existing VM.
- Explain replacement downtime, local disk loss, identity or enrollment loss,
  and the behavior of separately managed data.
- Do not enable the VM `migrate` behavior or mark LXC mount points `shared`
  without confirming the intended operation and underlying storage semantics.

## Document Operations

The README should cover purpose and scope, target node and placement reason,
dependencies, image/template source, local configuration, validation,
saved-plan review, architecture, ports, security boundaries, persistence,
backup ownership, replacement behavior, upgrades, import where useful, and
troubleshooting.

- State clearly that the cluster provides management membership, not automatic
  service HA.
- Keep commands generic and use semantic placeholders.
- Name required ports and protocols, but never provide environment-specific
  addresses or network identifiers.
- Recommend upstream DHCP reservation or DNS for stable discovery without
  recording the reservation.
- Explain which credentials, firewall rules, backups, application setup, and
  restore tests remain operator-managed.
- Use native systemd commands for native services and Compose commands for
  Docker services.
- For VM troubleshooting, include cloud-init and QEMU guest agent checks.
- For LXC troubleshooting, include service state plus the selected template,
  UID/GID mapping, mount, feature, and device assumptions that can fail.

## Validate Without Deployment

From the new service root:

1. Run `tofu fmt`.
2. Run `tofu init` to resolve the pinned provider and generate the lock file.
3. Run `make validate`, which should check OpenTofu formatting and validity plus
   all tracked YAML templates.
4. Run `git diff --check` and inspect the tracked diff for accidental network,
   storage, identity, credential, or secret values.

Do not run `make plan`, `tofu show`, or `make apply` by default. Planning needs
private local values, contacts the Proxmox cluster, and may expose infrastructure
details in tool output. If the user explicitly requests planning or applying,
use the saved-plan workflow and never repeat private values in the response.
