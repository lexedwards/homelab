---
name: create-a-service
description: Creates or changes an OpenTofu-managed homelab service under services/. Use for service placement, a Micro Node Incus instance, or a Proxmox VM, LXC, or appliance on compute or store. For an existing service, inspect its provider and placement before selecting a platform branch; never infer the platform from cloud-init, user-data, a package manager, systemd, Docker, or the services/ path alone.
---

# Create A Service

Create the smallest complete service root that fits the workload, its data, and
its host. Keep host bootstrap, image curation, guest infrastructure, application
provisioning, and operator-managed configuration at explicit lifecycle
boundaries.

## Core Workflow

Choose the path before implementation:

`TRACE -> ESTABLISH -> CLASSIFY -> CHOOSE BOUNDARY -> IMPLEMENT -> VERIFY`

Acceptance gates guard the transitions between stages. Pass each gate where it
appears before continuing; do not defer all acceptance checks until the end.

- **Trace:** locate the service and read current tracked evidence.
- **Establish:** define the workload, exposure, data, credentials, and readiness.
- **Classify:** preserve proven placement or choose a host from workload needs.
- **Choose boundary:** select the least-privileged viable guest and provisioning
  model.
- **Implement:** follow the selected platform reference and current repository
  conventions.
- **Verify:** validate locally without contacting infrastructure unless the user
  explicitly requests that operation.

## Core Principles

- Use OpenTofu. Use Terraform terminology only for ecosystem filenames such as
  `terraform.tfvars`.
- Read current tracked files before changing or judging a service. Do not inspect
  ignored local configuration, state, saved plans, or rendered cloud-init to
  discover deployment values. A saved plan may be inspected only for an
  explicitly requested plan or apply review under the freshness gate below.
- Apply the data classes in [Lifecycle And Operations](references/lifecycle-and-operations.md):
  never disclose secrets, do not repeat exact deployment locators, and preserve
  useful non-secret architecture already established in tracked documentation.
- Prefer a native package and one systemd service. Use Docker Compose only when
  a container runtime is justified; never use an imperative `docker run`
  lifecycle.
- Add privilege, devices, mounts, kernel settings, and security exceptions only
  for stated workload requirements.
- Use DHCP by default and keep stable addressing in upstream DHCP and DNS.
- Do not invent exposure, persistence, authentication, migration, high
  availability, or backup requirements.
- Never plan or apply infrastructure unless the user explicitly asks for that
  operation. Apply only a saved plan generated from the current configuration,
  inspected with `tofu show` in the current workflow, and unchanged since review.

## Trace

For an existing service, read its `README.md`, `main.tf`, and `versions.tf`
before loading platform guidance. Record its provider, host, guest type, and
existing lifecycle boundaries without assuming they should change. For a new
service, read the repository README and host documentation, but defer placement
until the workload is established.

## Establish The Service

Infer what the repository and upstream documentation already establish. Ask
only when a missing answer changes safety, public behavior, or lifecycle:

- What does the service do, and what is the authoritative installation method?
- Which ports, protocols, callers, and outbound dependencies are required?
- What CPU, memory, disk, acceleration, device, or kernel resources are needed?
- Which data is replaceable, which is durable, and what must survive replacement?
- Which credentials or enrollment steps remain operator-managed?
- What local, deterministic readiness check proves the service is usable?

Read [Lifecycle And Operations](references/lifecycle-and-operations.md) when the
service installs software, handles credentials, stores durable data, uses
Compose, or needs an operator runbook.

**Workload gate:** purpose, exposure, resources, data ownership, and readiness
are sufficient to implement safely. Only external operations such as credential
enrollment, firewall policy, backup execution, and restore testing may remain
operator-managed.

## Classify Placement

Preserve an existing service's proven platform unless the request changes its
placement or workload constraints make it invalid. For a new or deliberately
relocated service, compare the established workload with current host roles:

- Prefer Micro Node Incus for suitable lightweight services that must remain
  independent of the main Proxmox platform.
- Prefer Proxmox `compute` for general or CPU-bound work and workloads coupled
  to its local devices.
- Prefer Proxmox `store` for persisted-data-intensive and storage-coupled work.

For a new or relocated service, or a change to host resources, confirm the
chosen host has the required capacity, networking, storage, image, available
guest ID, and devices. During a normal offline task, use tracked evidence or ask
the user for missing inventory and stop before implementation. Offer a read-only
infrastructure query only with explicit authorization. A provisional placement
may be recorded but does not pass the placement gate.

If more than one placement remains viable and the trade-off changes failure
isolation or data lifecycle, ask the user to choose.

| Evidence | Classification | Read next |
| --- | --- | --- |
| `incus_instance`, the Incus provider, or explicit `micro-node` placement | Micro Node Incus | [Incus](references/incus.md) |
| `bpg/proxmox`, `proxmox_cloned_vm`, a `proxmox_virtual_environment_*` resource, or explicit `compute`/`store` placement | Proxmox | [Proxmox](references/proxmox.md) |

Cloud-init, user-data, package managers, systemd, Docker, VM, container, and the
`services/` directory are not sufficient platform evidence. If the request,
tracked files, and workload-based host comparison do not establish placement,
ask one concise question. Do not load a platform branch speculatively.

**Placement gate:** the target platform and host are supported by explicit
request, existing placement, or a workload-based decision against current host
roles, and all host prerequisites affected by the change are confirmed.

## Choose The Boundary

Follow the classified platform rather than choosing from all guest types at
once:

- **Micro Node Incus:** use an Incus container and load only the workload
  sections needed from [Incus](references/incus.md).
- **Proxmox:** establish `compute` or `store`, then choose a VM, unprivileged
  LXC, or reviewed appliance using [Proxmox](references/proxmox.md).
- **Proxmox VM:** read [Proxmox VM](references/proxmox-vm.md).
- **Proxmox LXC:** read [Proxmox LXC](references/proxmox-lxc.md). If repeatable
  application provisioning has no established mechanism, choose a VM or ask the
  user instead of hiding remote execution in OpenTofu.

Prefer Debian 13 only when the selected platform has a reviewed source for it
and the workload supports it. Otherwise choose an existing reviewed compatible
image or stop for an image-curation decision. The operating-system choice must
agree with package names, repository setup, service paths, and image metadata.

**Boundary gate:** the selected guest supports the required isolation,
provisioning, devices, persistence, and future lifecycle without unexplained
privilege exceptions.

## Implement A Complete Slice

Start from the common root and add branch-specific files only when needed:

```text
services/<service-name>/
|-- Makefile
|-- README.md
|-- main.tf
|-- terraform.tfvars.example
|-- variables.tf
`-- versions.tf
```

- Generate `.terraform.lock.hcl` with `tofu init`; never hand-write it.
- Use current provider and OpenTofu constraints from the selected repository
  references. Validate unfamiliar provider arguments against the pinned schema.
- Use kebab case for external service names and snake case for OpenTofu labels.
- Add `.yamllint`, `cloud-init/`, and `config/` only when the selected branch
  needs them.
- Keep required deployment values in typed, validated variables without
  defaults. In `terraform.tfvars.example`, leave secrets and exact deployment
  locators unassigned; established non-secret architecture conventions already
  present in tracked files may be shown.
- Mark discovered addresses and any unavoidable credential inputs or outputs as
  sensitive where supported. Explain that sensitivity redacts normal output but
  does not encrypt state.

**Security gate:** the authored configuration contains no secrets or unapproved
deployment-specific values, and every elevated capability has a documented
need.

**Lifecycle gate:** readiness is bounded and local where possible; replacement,
durable data, enrollment, upgrades, backups, and operator responsibilities are
documented.

## Verify

Run the narrowest relevant checks from the service root, then broaden to the
complete local validation workflow:

1. Run `tofu fmt`.
2. Run `tofu init` when provider initialization or lock-file generation is
   needed.
3. Run `make validate`, including OpenTofu format and validation plus every
   authored YAML, cloud-init, and service-configuration check.
4. Run `git diff --check` from the repository root.
5. Use `git status --short --untracked-files=all` to identify every intended
   changed or new file. Inspect all of those files, including untracked files,
   for whitespace errors, secrets, and unapproved deployment-specific values.
   Do not inspect ignored runtime or local configuration files.

Do not run `make plan`, `tofu show`, or `make apply` by default. For an explicit
plan or apply request:

1. Generate the saved plan from the current configuration.
2. Inspect that plan with `tofu show` in the current workflow without repeating
   secrets or deployment locators in the response.
3. Apply only if no configuration changed after plan generation and review.

If the user supplies a pre-existing plan whose provenance or freshness cannot
be proven, obtain explicit confirmation before applying it.

**Done gate:** placement is evidence-based, all applicable gates pass, relevant
checks succeed, and any deliberate validation gap or operator action is stated.

Report only the fields that apply:

```text
Implemented: [service behavior or lifecycle change]
Verified: [checks and acceptance evidence]
Remaining: [operator action, validation gap, or residual risk]
```
