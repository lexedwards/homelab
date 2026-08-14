---
name: create-micro-node-incus-service
description: Creates or changes Micro Node Incus service containers using OpenTofu and cloud-init. Use when adding an Incus instance, service, appliance, systemd workload, or Docker Compose workload under services/ for the Micro Node.
---

# Create A Micro Node Incus Service

Create a self-contained OpenTofu root under `services/<service-name>/`. Follow
the repository's current Incus service conventions while keeping host bootstrap
and service lifecycle separate.

## Non-Negotiable Rules

- Use OpenTofu. Do not introduce another IaC tool or describe the configuration
  as Terraform, except where an ecosystem filename such as
  `terraform.tfvars` is unavoidable.
- Use a Debian 13 cloud image unless the user requires another image.
- Set `security.nesting = "true"` for Debian 13 containers using systemd. This
  is required on the Micro Node even for a native, non-Docker workload.
- Prefer a Linux-native package and systemd service over a container runtime.
- If a container runtime is justified, use Docker Compose. Do not use or
  document an imperative `docker run` workflow.
- Add only the devices, kernel settings, AppArmor rules, and syscall
  interception required by the workload. `security.nesting` does not justify
  copying the Docker, TUN, forwarding, or AppArmor exceptions from another
  service.
- Never apply infrastructure unless the user explicitly asks for an apply.

## Protect Local Infrastructure Data

Treat all environment-specific network data and credentials as private, even
when they may not conventionally be called secrets.

- Never disclose, commit, default, or document real IP addresses, CIDRs,
  gateways, DNS servers, VLAN IDs, remote endpoints, tokens, passwords, or key
  material.
- Represent required network data as typed OpenTofu variables with no defaults.
  Values belong only in ignored local variable files, `TF_VAR_...` environment
  variables, or an approved secret store.
- Do not read ignored `terraform.tfvars`, state, saved plans, rendered cloud-init
  data, or other local files to discover values. Do not reproduce values from
  command output in chat, documentation, tests, examples, commit messages, or
  pull requests.
- A tracked `terraform.tfvars.example` may name required variables and explain
  where local values belong, but must not assign example IP, CIDR, VLAN, remote,
  credential, or key values. Do not use plausible dummy network values.
- Use semantic placeholders in commands and prose, such as `<remote-name>` and
  `<service-address>`. Loopback names such as `localhost` are acceptable for an
  in-instance health check because they disclose no topology.
- Mark address and credential outputs or variables `sensitive = true` where
  OpenTofu supports it. Explain that this redacts normal CLI output but does not
  encrypt local state.
- Prefer post-deployment enrollment for application credentials so secrets do
  not enter OpenTofu state or Incus configuration. If provisioning cannot work
  without a secret, explain the state exposure and obtain the user's decision
  before implementing it.

Before finishing, inspect only the tracked diff and remove any environment
value that escaped into it.

## Establish The Workload

Infer details from the request and repository where possible. Ask a concise
question only when a missing choice blocks a safe implementation. Establish:

- service name, purpose, and upstream installation guidance;
- native package or vendor-supported systemd installation availability;
- ports, protocols, intended callers, and outbound dependencies;
- CPU and memory limits;
- persistent paths, replacement consequences, and backup expectations;
- deterministic local readiness checks;
- required host devices, sysctls, capabilities, or security exceptions; and
- whether operator-managed enrollment must happen after deployment.

Do not silently invent exposure, persistence, privilege, or authentication
requirements.

## Read Current References

Use current tracked files rather than relying on stale copied snippets. Do not
open ignored runtime or state files.

1. Read `hosts/micro-node/README.md` for the host/service lifecycle boundary,
   trusted-client workflow, `default` storage pool, and unmanaged `br0` bridge.
2. Read `services/hello-world/` for the smallest end-to-end native systemd
   baseline.
3. Compare the other Incus roots and retain conventions common to them:
   `services/proxmox-qdevice/`, `services/tailscale-exit-node/`,
   `services/technitium-dns/`, and `services/uptime-kuma/`.
4. Use a specialized service only for the matching concern:
   `proxmox-qdevice` for authoritative SSH keys, `tailscale-exit-node` for a TUN
   device and forwarding, and `uptime-kuma` for Compose and protected data.
5. Match the provider and OpenTofu constraints currently common across the
   service roots. Do not guess newer versions.

If examples conflict, follow this skill's security and data-protection rules,
then follow the majority current pattern. Never copy a concrete network value
from an existing example.

## Create The Service Root

Normally create:

```text
services/<service-name>/
|-- .gitignore
|-- .yamllint
|-- Makefile
|-- README.md
|-- cloud-init/
|   `-- user-data.tftpl
|-- main.tf
|-- terraform.tfvars.example
|-- variables.tf
`-- versions.tf
```

Add `cloud-init/network-config.tftpl` only when explicit guest network behavior
is needed. Use DHCP by default and keep stable addressing in upstream DHCP/DNS,
not in tracked guest configuration. Never embed a static topology value.

Generate `.terraform.lock.hcl` with `tofu init`; do not hand-write it. Keep the
same local-state and saved-plan ignore rules and Makefile workflow used by the
other service roots.

## Implement The Incus Baseline

Unless the service has a documented reason to differ, the root must:

- configure the Incus provider from a required, non-empty `incus_remote`
  variable with no environment-specific default;
- read the `default` storage pool and assert that it uses the expected `dir`
  driver;
- read `br0` in the `default` project and assert it is an unmanaged bridge;
- create one `incus_instance` in the `default` project with `profiles = []`,
  `running = true`, and `boot.autostart = true`;
- use the current Debian 13 cloud image convention and require non-empty image
  input;
- set explicit, workload-appropriate CPU and memory limits;
- set `security.nesting = "true"` as required for Debian 13 and systemd on the
  Micro Node;
- attach a root disk from the `default` pool;
- attach `eth0` to `br0` as a bridged NIC, with the tag supplied by a required
  validated `instance_vlan_id` variable that has no default;
- pass tracked cloud-init templates through Incus configuration;
- wait for cloud-init to complete; and
- expose the Incus-reported address only as a sensitive output.

Use names derived consistently from the service's kebab-case directory name:
kebab case for external Incus names and snake case for OpenTofu labels.

## Provision Safely

For native deployment:

- Prefer distribution packages or a pinned, verified vendor repository.
- Use cloud-init to install the package and enable the systemd unit.
- Harden the service's authentication and listener configuration to its stated
  audience. Do not broaden access merely to simplify setup.
- Avoid piping a remote script into a shell. If upstream offers no practical
  alternative, document that the installer is unpinned and review the script's
  source and transport before using it.

For a justified Docker deployment:

- Install Docker and Compose through the chosen package source.
- Write a declarative `compose.yaml` with cloud-init and start it with
  `docker compose up --detach`.
- Pin images to the narrowest maintainable version policy and document whether
  a tag is mutable.
- Use Compose commands for upgrades, restarts, status, logs, and troubleshooting.
- Add Docker-specific Incus syscall interception only when actually required.

For both models, add an Incus creation-time `exec` check when readiness can be
tested locally and deterministically. Use bounded retries and fail the creation
when the daemon, required device, or local endpoint is not ready.

## Handle Persistence And Replacement

- Keep replaceable application binaries and first-boot configuration on the
  instance root disk.
- Use a separate custom Incus volume for irreplaceable application data when
  appropriate, mount it at the application's real data path, and consider
  `prevent_destroy = true`.
- State explicitly that `prevent_destroy` is not a backup. Require tested,
  off-host backups for important data.
- Document that changing cloud-init user data does not rerun first-boot setup on
  an existing instance. Explain replacement downtime, identity/enrollment loss,
  and data-volume behavior.

## Document Operations

The README should cover purpose and scope, dependencies, local configuration,
validation, saved-plan review, architecture, security boundaries, persistence,
replacement behavior, upgrades, import where useful, and troubleshooting.

- Keep commands generic and use semantic placeholders.
- Name required ports and protocols, but never provide environment-specific
  addresses or network identifiers.
- Recommend upstream DHCP reservation or DNS for stable service discovery
  without recording the reservation.
- Explain what remains operator-managed, especially credentials, application
  setup, firewall policy, and backups.
- Use native systemd commands for native services and Compose commands for
  Docker services.

## Validate Without Deployment

From the new service root:

1. Run `tofu fmt`.
2. Run `tofu init` to resolve the pinned provider and generate the lock file.
3. Run `make validate`, which should check OpenTofu formatting and validity plus
   all tracked cloud-init YAML templates.
4. Run `git diff --check` and inspect the tracked diff for accidental network,
   identity, credential, or secret values.

Do not run `make plan`, `tofu show`, or `make apply` by default. Planning needs
private local values, contacts the Incus host, and may expose infrastructure
details in tool output. If the user explicitly requests planning or applying,
use the saved-plan workflow and never repeat private values in the response.
