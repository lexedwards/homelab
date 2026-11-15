# Lifecycle And Operations

Read with the main skill before choosing bootstrap, secrets or maintenance logic.

## Initial Environment

Cloud-init owns the unattended, non-secret baseline: networking, users, SSH keys,
repositories, dependencies, static configuration and systemd units/timers/drop-ins.

- Use the pinned [HashiCorp cloudinit provider][cloudinit] to compose user-data.
  Prefer native fields such as `apt`, `yum_repos`, `packages`, `write_files`,
  `mounts`, SSH host-key generation and `power_state` over scripts that recreate
  their behavior. Declare account/group membership instead of late `usermod`. Use
  `yamlencode` or simple YAML templates; keep network-data separate where required.
- The provider assembles MIME; it does not validate cloud-init module semantics.
  Verify target support for MIME, encoding/compression and module ordering.
  Keep vendor-data only for a genuinely shared, supported image baseline.
- Prefer distribution packages or pinned, verified vendor repositories. Preserve
  package pins and key/checksum provenance. Do not pipe a mutable remote installer
  into a shell when a supported declarative path exists.
- Keep only imperative steps addressing a demonstrated native gap, with one
  bounded purpose. Do not move a mixed installer into another data channel or
  weaken repository update exclusions just to fit the native package module.
- Write repository policy and systemd start conditions before package installation;
  package scripts may otherwise start daemons with default configuration. Use
  deferred writes only when package-created users/groups exist by that stage.
  For a justified later package helper, declare post-install ownership/directories
  through systemd-tmpfiles instead of scripting `chown`/`chmod`. Inspect package
  hooks for persistent-data side effects before allowing installation.
  Activate only after configuration/enrollment and any required kernel reboot.
  Installing a kernel does not load its modules; failed installation must not
  enable an unsafe start or enrollment.
- Use DHCP and upstream reservations/DNS for stable addressing. Verify effective
  network rendering on the target OS, not just YAML syntax. Where a renderer drops
  required settings, use its supported native configuration instead of post-boot
  profile repair, interface restarts, invented MACs or static-IP workarounds.
  For DNS services, preserve upstream guest resolution independently of the daemon;
  declare listener conflicts and resolver-file ownership rather than copying an
  installer's loopback resolver rewrite.

Changing cloud-init does not update an existing guest. Keep first boot, controlled
maintenance and replacement separate; never reprovision initialized data.

## Secret Handling

OpenBao is the secret provider. Secrets must never enter Git, OpenTofu state/plans,
cloud-init, argv, logs or tracker evidence. Sensitivity markings only redact display.
For input classification, read and apply
[Configuration Values](../../principle-configuration-values/SKILL.md).

- VM/LXC consumers connect directly using simple Bash and native CLIs/APIs. Use
  systemd units, timers, protected environment/credential files and drop-ins for
  execution and activation. Keep files least-privileged and disable secret logging.
- Kubernetes consumers use cluster integration such as CSI, not per-pod bootstrap
  scripts. Runtime readers must not administer their own authorization.
- Establish initial machine trust separately. AppRole SecretIDs and response-
  wrapping tokens are credentials, not public bootstrap data. Do not grant access
  merely because a guest knows a role name or is on a private subnet.
  For VM/LXC introduction, follow the accepted [trusted SSH enrollment decision]:
  wrapped delivery, reusable root-only SecretIDs and short-lived runtime tokens,
  without another broker or guest-agent credential transport.
- Keep recovery access independent of the service/failure domain it recovers.
  OpenBao's own TLS renewal and recovery must not depend on fetching from sealed
  OpenBao. Reload is not restart: certificate SIGHUP preserves unsealed operation;
  a process restart requires operator unseal under the current policy.

## Privileged Procedures And Maintenance

Use small service-local Bash procedures with explicit inputs and native commands.
Consider Ansible only where repeated orchestration demonstrably warrants it; do
not add a framework solely to wrap commands. Keep supported declarative API
configuration in its OpenTofu owner; separate credential issuance/value enrollment.

- Document invocation, prerequisites, privilege, side effects, completion checks
  and failure/retry behavior. Preserve identity and refuse unsafe overwrites.
- Make OpenBao initialization, recovery-material custody, scoped access setup and
  root-token revocation separate stages. Initialize only uninitialized storage;
  uncertain output custody is a stop condition, not permission to initialize again.
  Capture recovery output directly into exclusively created protected custody,
  never a terminal/log stream. Verify independent custody separately from local
  capture, and scoped access before revoking initial root access. Preserve manual
  unseal; initialization must not silently continue into later stages.
- Reuse authoritative version/configuration inputs between fresh bootstrap and
  maintenance; do not create independent definitions. A helper's compatibility
  limits remain distinct from the desired version.
- Use native controllers, agents and systemd timers for recurring work. Readiness
  checks must be bounded and must distinguish waiting for enrollment from failure.
  Keep guest package/configuration maintenance out of provisioners. The explicit
  credential-introduction hook is separate from VM resources, fails without VM
  replacement, and must not become a configuration-repair mechanism.

## Runtime And Data

Prefer native packages and systemd services. When Docker is justified, use a
declarative Compose file managed by systemd, not `docker run`. Pin images under an
explicit update policy; drop unnecessary capabilities, use `no-new-privileges`,
bound log growth and publish only required ports where supported.
Keep Compose configuration native-validated without requiring a running daemon;
an active oneshot wrapper is not application-health evidence.

Separate replaceable software/configuration from durable data. Document deletion,
replacement, migration, backup ownership and restore limitations for every durable
path and identity. Protection, RAID and replication are not application-consistent
backups. State backup and application backup have different recovery roles.

The service README owns applicable dependencies, exposure, state/data ownership,
validation, readiness, enrollment, upgrade and recovery commands. Keep examples
generic and follow repository documentation privacy. Record actual acceptance and
remaining live checks in the tracker, not transient handoff documents.

[cloudinit]: https://registry.terraform.io/providers/hashicorp/cloudinit/latest/docs
[trusted SSH enrollment decision]: ../../../../docs/adrs/011-ssh-approle-enrollment.md
