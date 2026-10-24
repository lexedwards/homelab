# Lifecycle And Operations

Read this reference when a service installs software, handles credentials,
stores durable data, uses Docker Compose, or needs operational documentation.

## Configuration And Credentials

Before choosing tracked values, local inputs, or defaults, read and apply
[Configuration Values](../../principle-configuration-values/SKILL.md).
A saved plan may be inspected only during an explicitly requested plan or apply
review; never quote its protected values.

Keep application credentials out of OpenTofu state and first-boot data. Prefer
post-deployment enrollment with a root-owned credential file. If first boot
cannot work without a secret, explain its state exposure and obtain the user's
decision before implementing it. Mark every unavoidable credential variable and
output as sensitive where OpenTofu supports it; sensitivity redacts normal
output but does not encrypt state.

## Provision Software

### Native

- Prefer a distribution package or pinned, verified vendor repository.
- Install and enable one clear systemd unit.
- Make repository setup, package names, package versions, administrator groups,
  filesystem paths, and service environment files agree with the selected OS.
- Harden listeners and authentication to the stated audience. Do not broaden
  access for setup convenience.
- Avoid piping a remote script into a shell. If no practical alternative exists,
  review its source and transport and document that it is unpinned.

### Docker Compose

- Use a declarative `compose.yaml`; never document an imperative `docker run`
  lifecycle.
- Pin images to the narrowest maintainable policy and document mutable tags.
- Drop capabilities, use `no-new-privileges`, bound log growth, and publish only
  required ports where supported.
- Use Compose commands for upgrades, restarts, status, logs, and troubleshooting.
- Follow the selected platform reference for runtime placement and startup.

## Prove Readiness

- Use a deterministic local check when possible.
- Bound retries and elapsed time.
- Fail provisioning when a required daemon, device, or local endpoint is not
  ready and the selected platform supports that enforcement.
- Do not wait on credentials or enrollment that the operator performs later.
- Do not create unbounded OpenTofu waits or remote-execution provisioners.

## Handle Data And Replacement

- Separate replaceable binaries and configuration from irreplaceable data where
  the storage design supports it.
- Record what destroy and replacement do to every persistent path, disk, volume,
  and identity.
- Explain downtime, local data loss, enrollment loss, and separately managed
  data behavior.
- State that changing cloud-init updates tracked first-boot input but does not
  rerun it on an existing guest.
- Require tested backups in another fault domain for important data. Protection,
  lifecycle rules, RAID, replication, and live filesystem copies are not
  application-consistent backups.

## Document Operations

The service README should cover only applicable concerns:

- purpose, scope, architecture, target host, and placement reason;
- dependencies, image or template source, and local configuration;
- ports, callers, outbound dependencies, and security boundaries;
- validation and saved-plan review;
- persistence, backup ownership, replacement, and restore expectations;
- upgrades, import, status, logs, and troubleshooting; and
- operator-managed credentials, enrollment, firewall policy, backups, and
  restore tests.

Keep commands generic and use semantic placeholders. Recommend upstream DHCP
reservations or DNS for stable discovery without recording the reservation. Use
systemd commands for native services and Compose commands for Compose workloads.
