# Micro Node Incus

Read this reference only after the main skill's placement gate classifies the
service for the Micro Node and Incus.

## Read Current Evidence

1. Read `hosts/micro-node/README.md` for the host/service boundary, trusted
   client workflow, `default` storage pool, and unmanaged `br0` bridge.
2. Read `services/hello-world/` for the smallest native systemd baseline.
3. Compare current Incus roots: `services/proxmox-qdevice/`,
   `services/tailscale-exit-node/`, `services/technitium-dns/`, and
   `services/uptime-kuma/`.
4. Use specialized examples only for their matching concern:
   `proxmox-qdevice` for authoritative SSH keys, `tailscale-exit-node` for TUN
   and forwarding, and `uptime-kuma` only for custom-volume persistence and
   replacement. Do not copy Uptime Kuma's Docker startup, hardening, or upgrade
   lifecycle.
5. Use provider and OpenTofu constraints common to current roots. Do not guess
   newer versions.

If examples conflict, preserve the unified skill's security rules, then follow
the current majority pattern. Never copy an environment value.

## Incus Acceptance Gates

### Host Gate

- Configure the provider from a required, non-empty `incus_remote` variable
  without an environment-specific default.
- Read the `default` storage pool and assert its expected `dir` driver.
- Read `br0` in the `default` project and assert that it is unmanaged.
- Use the `default` project and no inherited profiles.

### Guest Gate

- Create one `incus_instance` with `running = true` and
  `boot.autostart = true`.
- Use the current Debian 13 cloud-image convention unless package support or the
  workload requires another OS. Require a non-empty image input.
- Set explicit workload-appropriate CPU and memory limits.
- Do not enable `security.nesting` by default. Add it only when current evidence
  demonstrates a host, guest, or workload requirement, and document that reason.
  Systemd use or an inherited example alone is insufficient.
- Attach the root disk from the `default` pool.
- Attach `eth0` to `br0`; supply its tag through a required, validated
  `instance_vlan_id` variable without a default.

### Provisioning Gate

- Add `.yamllint` and `cloud-init/user-data.tftpl` to the common service root.
- Add `cloud-init/network-config.tftpl` only for explicit guest network behavior.
- Pass tracked cloud-init through Incus configuration and wait for completion.
- For native software, install the package and enable systemd through cloud-init.
- No conforming tracked Incus Compose example currently exists. For justified
  Docker Compose, install the runtime through the selected package source, write
  the declarative Compose file through cloud-init, apply the hardening in
  [Lifecycle And Operations](lifecycle-and-operations.md), and manage startup
  and upgrades through a dedicated systemd unit that invokes Compose. Add
  Docker-specific syscall interception only when proven necessary.
- Use a bounded creation-time `exec` check when readiness can be tested locally
  and deterministically.

### Data Gate

- Keep replaceable binaries and first-boot configuration on the root disk.
- Use a custom Incus volume for irreplaceable application data when appropriate,
  mounted at the application's actual data path.
- Consider `prevent_destroy = true` for the durable volume, and state that it is
  not a backup.
- Document custom-volume behavior during instance replacement.

### Output Gate

- Derive external names from the kebab-case service directory and use snake case
  for OpenTofu labels.
- Expose the Incus-reported address only as a sensitive output.
