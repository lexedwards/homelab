# OpenBao

OpenBao runs as a native systemd service in one Debian 13 ARM64 Incus container
on [Micro Node]. It uses integrated Raft storage on a separate custom volume,
outside the Proxmox failure domain. This is a single server, not an HA cluster.

> [!WARNING]
> Temporary private-network HTTP is an explicitly accepted deployment exception.
> Tokens, unseal shares, and secret values sent to the network API are not
> encrypted in transit. Local networking is not a substitute for TLS. Do not
> expose this endpoint to the internet. TLS issuance and migration remain deferred.

## Dependencies

- OpenTofu 1.9 or newer, `make`, `yamllint`, Python 3, and the matching OpenBao
  CLI for the workstation architecture for local validation. Verify its release
  signature/checksum before use; set `BAO_BIN` if it is not on `PATH`.
- A trusted Incus client, the Micro Node `default` directory storage pool, and
  unmanaged `br0` bridge.
- A reviewed Debian 13 ARM64 cloud image. The upstream Incus image catalogue
  provides `images:debian/13/cloud/arm64`; supply the reviewed reference locally.
- Upstream VLAN connectivity, DHCP, routing, DNS, and firewall policy permitting
  only intended private clients to reach TCP 8200.
- An existing Technitium zone and an API token injected through
  `TECHNITIUM_API_TOKEN`. Do not put the token in OpenTofu input files.

The guest needs outbound access to Debian package mirrors and GitHub releases
over HTTPS. The API and UI listen on TCP 8200; the single-node cluster listener
uses loopback TCP 8201 and is not published to the network.

The initial resource limit is one CPU and 1 GiB RAM. Monitor memory, disk, and
request load before increasing usage. The guest remains unprivileged and has no
raw AppArmor overrides or Docker-specific exceptions.

`security.nesting=true` is required for Debian 13 systemd startup on the current
Micro Node Ubuntu/Incus host. Without it, `sd-mkuserns` helpers blocked networking,
DNS resolution, and journaling, preventing DHCP and cloud-init completion. A
controlled test changing only nesting and restarting the guest restored those
services; OpenBao then started and passed its effective/kernel swap-limit checks.
Nesting relaxes container confinement beyond a targeted AppArmor rule, but does
not make the guest privileged or disable AppArmor. Do not copy Technitium's
application-specific signal rule. Reassess the exception after host/runtime
changes and verify a successful boot without nesting before removing it.

## Configure And Validate

Copy `terraform.tfvars.example` to ignored `terraform.tfvars`. Set the Incus
remote, ARM64 image, service VLAN, Technitium API URL, existing DNS zone, and
private fully qualified service name. Keep all deployment-specific values local.
Optional sizing and DNS TTL inputs have defaults in `variables.tf` and
`record-variables.tf`.

```bash
make init
make validate BAO_BIN=<verified-bao-binary>
```

Validation runs format/OpenTofu checks, YAML template linting, installer syntax,
mocked provider plans, rendered cloud-init checks, readiness unit tests, and two
starts of a disposable, uninitialized server using the rendered configuration.
The server test substitutes a temporary data directory and loopback high ports,
creates no secrets, and removes its scratch files after stopping the process.
The smoke test uses an isolated root with synthetic inputs and no deployment
state or local tfvars; it reuses only the initialized provider binaries. Validation
does not contact infrastructure, install the package, or prove systemd/cgroup
behavior inside a new guest.

OpenBao 2.7.2 is installed from the upstream ARM64 DEB. The version and SHA-256
are kept together in `main.tf`. Before changing either, verify the release
manifest's GPG signature using the upstream published key, then verify the
package against that manifest. The installer rejects a checksum mismatch or
an incompatible guest OS/architecture. It preserves the authored server config
instead of activating the package's example configuration.

## Deploy And Register DNS

Planning and applying require separate authorization. After supplying inputs
and credentials, generate and inspect the current saved plan:

```bash
make plan
tofu show deployment.tfplan
make apply
```

Apply only the reviewed saved plan, with no intervening configuration changes.
Protect plans and state: they contain topology and rendered first-boot
configuration even though initialization keys and application secrets are absent.

The root registers one A record using Incus's reported guest IPv4 address.
It does not own the shared zone or overwrite sibling records. If the same record
already exists, establish ownership/import it before applying; do not enable
overwrite to hide a conflicting owner.

Reserve the guest's DHCP lease upstream before relying on its DNS entry. Obtain
the guest MAC from Incus after creation, establish the reservation, and reconcile
the reviewed plan if the address changes. This root neither reserves DHCP leases
nor continuously tracks address changes. After guest replacement, verify its MAC,
reservation, address, and DNS again before clients reconnect.

The creation check verifies an active service, its effective swap limit, the
kernel service-cgroup limit, and a valid local health response. Uninitialized or
sealed is an expected initial state; successful provisioning does **not** mean
secrets are usable. It neither initializes nor unseals the server.

## Initialize Once And Unseal Manually

Choose the Shamir share count and threshold with the operator before
initialization. Store shares securely outside this server and outside OpenBao,
Git, OpenTofu, cloud-init, logs, and issue discussions. Keep a recoverable copy
outside Micro Node's failure domain. The defaults are five shares with a
threshold of three; they are not an automatically selected custody policy here.

Run these commands yourself in a private interactive terminal, not an agent
transcript. Using `incus exec` with the loopback endpoint avoids sending the
administrative request over the plaintext guest network:

```bash
incus exec <remote>:openbao -- env BAO_ADDR=http://127.0.0.1:8200 bao status
incus exec <remote>:openbao -- env BAO_ADDR=http://127.0.0.1:8200 bao operator init -key-shares='<share-count>' -key-threshold='<threshold>'
incus exec <remote>:openbao -- env BAO_ADDR=http://127.0.0.1:8200 bao operator unseal
```

Initialize **only new, uninitialized storage**, once. Securely collect its output.
Run `operator unseal` interactively for the required number of distinct shares;
never put shares in command arguments. A sealed status returns exit code 2 and
does not mean storage needs reinitializing.

Use the initial root token only to establish scoped administration, authentication,
and the required secret engine. Inject credentials securely without command-line
arguments or tracked files. Verify a separate scoped administrator login before
revoking the initial root token with `bao token revoke -self`. Clear any cached
copy and environment variable; deleting a copy alone does not revoke the token.
Do not use the root token for routine OpenTofu runs.

Every OpenBao process restart seals the server again. Supply the threshold of
shares to recover access. Service roots consuming credentials from OpenBao
cannot plan/apply successfully while it is unavailable or sealed. Keep an
independent Incus/DNS bootstrap and recovery credential path.

## Configuration Ownership

Service-specific secret paths, supported metadata, policies, and authentication
roles belong with the owning service, like its DNS records. Shared secret-engine
mounts and authentication backends are platform-owned. Every object has one
OpenTofu owner; do not create a second writer in a central root.

This initial hosting slice does not configure the OpenBao API through OpenTofu.
API configuration requires initialization/unseal and a separate scoped identity.
Keep populating actual secret values separate from declaring configuration:
ordinary secret resources/data sources can persist values in state and saved
plans. Sensitive marking only redacts display. Runtime identities must not be
able to edit their own access policies.

## Verify And Operate

The non-secret check can be rerun read-only:

```bash
incus exec <remote>:openbao -- python3 /usr/local/lib/openbao/check-ready.py
incus exec <remote>:openbao -- systemctl cat openbao
incus exec <remote>:openbao -- systemctl show openbao -p MemorySwapMax -p ControlGroup
incus exec <remote>:openbao -- journalctl -u openbao --no-pager
```

`check-ready.py` requires effective `MemorySwapMax=0` and the actual service
cgroup's `memory.swap.max=0`. A missing/unavailable control fails the check;
an ancestor's no-swap setting alone is not accepted as proof of the service
setting. The guest also disables swapping at the Incus boundary. The package
supplies its dedicated account and systemd sandbox; a drop-in preserves swap
protection, disables core dumps, and denies access to home directories.

After separately authorized deployment, verify DNS from an intended client,
initialize/unseal privately, and test authenticated write/read of disposable data
with a scoped identity. Verify unauthenticated secret reads are denied. Use a
durable KV path for restart tests, not a token's ephemeral cubbyhole. Delete test
data afterwards. Do not publish tokens, share values, or secret contents.

Before an authorized service or guest restart, confirm share availability and
accept downtime. After restarting, unseal manually, repeat the non-secret check,
and verify the disposable secret and DNS. No deployment, restart, replacement,
authenticated smoke test, or restore is implied by local validation.

## Persistence, Backup, And Recovery

The protected `openbao-data` volume mounts at `/opt/openbao/data`. Package files,
server configuration, and verification scripts live on the replaceable root
disk. `prevent_destroy` prevents routine OpenTofu destruction while the resource
declaration remains; it is not protection from removing the declaration, manual
Incus deletion, host loss, or corruption, and is not a backup.

Keep application-consistent Raft snapshots in a protected location outside the
host failure domain, alongside independent key custody and rebuild inputs.
An operator with the appropriate scoped permission can use
`bao operator raft snapshot save <protected-path>`. Do not copy a live Raft
directory as a substitute for a supported snapshot. Snapshots remain sensitive
and require the corresponding key material to recover secrets. Backup scheduling,
destination, retention, and restore testing are operator-managed and not yet
automated by this service.

Before storing irreplaceable secrets, arrange and test independent recovery.
Test restoration only on an explicitly authorized isolated target; prevent it
from registering the production name or making unintended external calls.
Follow the matching version's upstream snapshot restore procedure, retain the
original recovery material, and do not initialize the production volume again.
No backup or restore test has been performed by this implementation.

Guest replacement must stop/detach the old instance before attaching its durable
volume to the replacement. Never run two servers against the same volume.
Provisioning preserves data, reapplies directory ownership, starts sealed, and
does not initialize existing storage. Reconfirm DHCP/DNS after replacement.

## Changes And Upgrades

Cloud-init is first-boot provisioning: changing its OpenTofu value does not rerun
installation or reconfigure an existing guest. Inspect each plan for replacement
and do not assume an in-place config update has taken effect.

Before upgrading, read upstream compatibility notes, make a verified snapshot,
confirm key availability and rollback/recovery steps, and authorize the downtime.
Update the package version and verified checksum together. Use a controlled
in-guest package/config update or an explicitly reviewed instance replacement
with the retained volume, then unseal and verify. Never assume a package downgrade
can read an upgraded storage format; rollback may require an isolated restore
using the matching old binary and snapshot.

When adding TLS, replace the HTTP listener and advertised API scheme, enroll
certificates outside state/cloud-init, establish renewal and client trust, and
update checks and clients together. Merely changing DNS does not secure HTTP.

[Micro Node]: ../../hosts/micro-node/README.md
