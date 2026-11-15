# Micro Node Incus

Read this reference only after the main skill classifies the
service for the Micro Node and Incus.

## Read Current Evidence

1. Read `hosts/micro-node/README.md` for the host/service boundary, trusted
   client workflow, `default` storage pool, and unmanaged `br0` bridge.
2. Read `services/hello-world/` for a small Incus baseline and `services/openbao/`
   for Debian 13 nesting, TLS-gated activation, a bounded verified-package helper
   and native tmpfiles ownership. Its initialization/unseal are separate operations.
3. Use `tailscale-exit-node` for native vendor APT, TUN and forwarding, and
   `uptime-kuma` for systemd/Compose startup and custom-volume persistence.
   `technitium-dns` demonstrates pinned .NET packages and a verified application
   archive; its initial administration still requires protected enrollment.
   Their device/syscall exceptions are workload-specific. QDevice retains its
   existing ongoing SSH-key ownership; it is not a new first-boot key recipe.
4. Use provider and OpenTofu constraints common to current roots. Do not guess
   newer versions.

Follow the lifecycle reference over conflicting legacy examples. Never copy an
environment value or assume an older installer is the recommended bootstrap.

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
- For Debian 13 containers on the current Micro Node Ubuntu/Incus host, set
  `"security.nesting" = "true"` in the instance configuration. An OpenBao boot
  test verified that enabling nesting and restarting cleared `sd-mkuserns` hangs in
  `systemd-networkd`, `systemd-resolved`, and `systemd-journald`, allowing DHCP,
  cloud-init, and native OpenBao startup; service-cgroup swap enforcement still
  passed. Document this host-compatibility exception in the service README.
- Keep the guest unprivileged. Nesting relaxes confinement but does not require
  disabling AppArmor, changing host-wide sysctls, or copying Technitium's
  application-specific `raw.apparmor` signal rule. For other OS/host combinations,
  add nesting only with evidence of a requirement. Reassess this exception after
  host/runtime changes; remove it only after a verified no-nesting boot with
  networking, cloud-init, and required service hardening intact.
- Attach the root disk from the `default` pool.
- Attach `eth0` to `br0`; supply its tag through a required, validated
  `instance_vlan_id` variable without a default.

### Provisioning Gate

- Follow [Lifecycle And Operations](lifecycle-and-operations.md) for declarative
  cloud-init composition, package installation, secret handling and maintenance.
- Pass rendered user-data and separate network-data through the supported Incus
  configuration keys; verify format/encoding support and wait for cloud-init.
- For justified Compose, follow the lifecycle reference and Uptime Kuma's dedicated
  unit/config pattern, not an imperative `docker run` upgrade procedure. Add
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
