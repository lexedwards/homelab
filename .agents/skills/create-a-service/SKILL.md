---
name: create-a-service
description: Creates or changes homelab services with OpenTofu-owned infrastructure, native cloud-init bootstrap, and service-local lifecycle ownership. Use for service placement or changes on Micro Node Incus or Proxmox compute/store. Classify existing services from their tracked provider and placement before loading platform guidance.
---

# Create A Service

Deliver one complete service change, including its validation and operating
guidance. Existing examples are implementation evidence, not permission to copy
obsolete provisioning, credentials or environment values.

## Trace And Establish

1. Read the repository README and the service's `README.md`, `main.tf` and
   `versions.tf`. For a new service, read the host documentation instead.
2. Establish purpose, exposure, dependencies, resources, durable data, credentials
   and readiness. Ask only for missing decisions that affect safety or lifecycle.
3. Read and apply [Configuration Values](../principle-configuration-values/SKILL.md)
   before authoring inputs, defaults or examples, and
   [Lifecycle And Operations](references/lifecycle-and-operations.md) for bootstrap,
   secret handling, maintenance and recovery.
4. Trace module sources, file/state reads and script imports against the ownership
   rules below before choosing an implementation.

Read tracked evidence only. Do not inspect ignored tfvars, state, saved plans,
credential files or rendered deployment artifacts to discover local values.
Saved-plan review is limited to an explicitly authorized infrastructure operation.

## Enforce Service Ownership

**deployments, modules, resources etc. DO NOT mix across the services/ boundary**

- Each `services/<name>/` owns its deployments, resources, state and lifecycle.
  Private templates, modules and scripts stay within that service. Never import
  another service's implementation, tfvars or state.
- Put cross-service reusable implementation in repository-level `modules/`.
  Keep modules small, with straightforward inputs; do not build a provisioning
  framework. Their resources belong to the caller, not a shared deployment.
- Integrate through APIs or published non-secret outputs supplied to consumers.
  Do not duplicate endpoints or grant access to another service's whole state.
  Multiple roots within one service may use its documented metadata/state contract.
- Machine infrastructure is always declared in OpenTofu. Scripts and configuration
  management must not become alternative infrastructure or API-resource owners.

Extract shared code or establish an explicit interface before introducing a
cross-service dependency.

## Classify Placement

Preserve existing placement unless the request changes it or demonstrated
workload constraints invalidate it. Cloud-init, Docker, systemd, package managers
and the `services/` path do not identify a platform.

For new or relocated services:

- Prefer Micro Node Incus for suitable lightweight services requiring independence
  from Proxmox, `compute` for general/CPU/device-coupled workloads, and `store` for
  persisted-data-intensive or storage-coupled workloads.
- Confirm affected capacity, bridge, storage, image/template, guest ID and devices
  from tracked evidence or operator input. Request authorization before querying
  infrastructure. Do not turn provisional placement into an implemented assumption.
- Ask when viable choices materially change failure isolation or data lifecycle.

Load only the established platform branch:

| Tracked evidence | Read and apply |
| --- | --- |
| `incus_instance`, Incus provider or Micro Node placement | [Incus](references/incus.md) |
| `bpg/proxmox` or Proxmox resources/placement | [Proxmox](references/proxmox.md), then its selected VM/LXC reference |

Prefer Debian 13 only where a reviewed image exists and the workload supports it.
Otherwise use a reviewed compatible OS or resolve image curation first. Require
evidence for privilege, kernel, device and confinement exceptions; do not invent
exposure, persistence, migration, HA or backup requirements.

## Implement

Start with `Makefile`, `README.md`, `main.tf`, `variables.tf`, `versions.tf` and
`terraform.tfvars.example` in the owning service. Add cloud-init, configuration
and private modules only as needed.

- Follow the selected platform reference and the lifecycle ownership rules.
- Use pinned provider constraints and verify unfamiliar arguments against their
  schema. Generate lock files with `tofu init`; never hand-write them.
- Use kebab-case service names and snake_case OpenTofu labels. Mark discovered
  addresses as sensitive outputs.
- Keep declarations, examples, commands and documentation aligned. Review the
  root overview and affected diagrams when relationships change.
- With each slice, review this entire skill and all references: replace stale
  instructions, remove conflicts and repetition, check links/examples, and keep
  each rule in one authoritative location. Do not merely append corrections.

## Verify Locally

1. Run relevant formatting, syntax, lint and native configuration/schema checks.
   Initialize isolated provider directories when needed, then run `make validate`.
2. Keep OpenTofu tests only for meaningful dynamic transformations/parsing not
   adequately checked by variable validation, lifecycle conditions or native tools.
   Do not add Python tests or static/intention tests, or replace them with custom
   assertion scripts. Operational health/readiness commands remain distinct.
3. Run `python3 -B scripts/check-service-boundaries.py` from the repository root.
   It covers literal local OpenTofu paths only; review dynamic references and
   script imports manually.
4. Run `git diff --check` and inspect every intended changed/new file, including
   untracked files, for secrets and unapproved deployment values. Do not inspect
   ignored runtime artifacts.

Distinguish YAML lint, rendered cloud-config schema validity, effective target
renderer/native-consumer behavior and deployed acceptance. In particular,
schema-valid network-data may be ignored by a target renderer. Report unperformed
checks rather than inferring runtime success from local validation.

Walk through affected fresh-bootstrap, unsupported-renderer, credential-gated and
existing-initialized-service paths. Preserve working network behavior and stop at
the proper enrollment/reboot boundary; never rerun first boot to repair useful data.

## Authorized Operations

Do not plan/apply, initialize, issue credentials, restart or replace services
without authorization. Proceed within an approved bounded operation; ask again
only when mutation, disruption or data-loss scope materially changes.

Use canonical `main` and existing production state for persistent operations;
worktrees are for development and local validation, not competing deployment state.
Generate a fresh saved plan, inspect it with `tofu show`, and apply only that
unchanged plan/configuration. A supplied plan with unproven provenance/freshness
needs explicit confirmation. Keep protected values out of published evidence.

Keep active issue status and operational evidence in the tracker. Report
implementation, local verification, deployed acceptance and outstanding operator
actions separately; a merged PR alone does not prove pending runtime criteria.
