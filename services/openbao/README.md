# OpenBao

OpenBao runs as a native systemd service in one Debian 13 ARM64 Incus container
on [Micro Node]. It uses integrated Raft storage on a separate custom volume,
outside the Proxmox failure domain. This is a single server, not an HA cluster.

> [!WARNING]
> The existing initialized instance needs the separately authorized in-place
> migration below. Updating cloud-init does not migrate it. New installations
> remain stopped until out-of-band certificate enrollment; never initialize
> existing storage again or replace the guest to enable TLS.

## Dependencies

- OpenTofu 1.9 or newer, `make`, `yamllint`, Python 3, OpenSSL, bubblewrap, and the matching OpenBao
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

The guest needs outbound HTTPS to Debian package mirrors, GitHub releases,
Let's Encrypt and Cloudflare's API, plus working DNS. Cloudflare must be the
public authoritative DNS provider for the certificate name. Technitium resolves
that name to the private guest address. Do not publish an OpenBao A/AAAA record
or open inbound ACME ports: DNS-01 needs only public challenge TXT records.
Public issuance exposes the certificate name in certificate-transparency logs.
The native HTTPS API and UI listen on TCP 8200; the single-node cluster listener
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
starts of a disposable server using the rendered configuration. The server test
substitutes temporary storage, synthetic certificates and loopback high ports.
It initializes only disposable storage, verifies synthetic authenticated access
survives a certificate reload without restart or reseal, then restarts sealed.
It removes its scratch files after stopping the process. Bubblewrap isolates
certificate deployment tests from the workstation's accounts, files and systemd.
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

Before enrollment, the creation check accepts only an enabled but inactive service
whose certificate conditions failed, with both TLS files absent. It explicitly
reports that the API is not ready. Once enrolled, the normal check requires
verified HTTPS, matching served/deployed certificates, effective and kernel
swap limits, and valid health. Sealed is not secret-ready. Neither check
initializes nor unseals storage.

## Enroll Native HTTPS

Use Debian's `certbot` and `python3-certbot-dns-cloudflare` packages with
Let's Encrypt. The Cloudflare token needs `Zone:DNS:Edit` for only the required
zone (and zone discovery access required by the plugin). Do not use a global API
key. In a private terminal, create `/etc/openbao-acme/cloudflare.ini` as root,
mode `0600`, beneath its root-owned `0700` directory. Its single setting is
`dns_cloudflare_api_token = <token>`. Inject the value out of band, never through
OpenTofu, cloud-init, shell arguments, source control, or issue comments.
Keep independent recovery copies of this credential and ACME recovery material
outside OpenBao and Micro Node; do not make renewal depend on the service it secures.

After explicit authorization for public DNS writes and issuance, run inside
the guest, replacing the non-secret placeholders:

```bash
certbot certonly --non-interactive --agree-tos --email '<operator-email>' \
  --dns-cloudflare --dns-cloudflare-credentials /etc/openbao-acme/cloudflare.ini \
  --dns-cloudflare-propagation-seconds 60 --cert-name openbao \
  -d '<private-service-fqdn>' \
  --deploy-hook /usr/local/lib/openbao/deploy-certificate.sh
```

The deploy hook validates public trust, hostname, expiry and key pairing before
atomically publishing a root-owned, OpenBao-readable certificate/key generation.
Private keys stay on the guest, outside state and cloud-init. Previous generations
remain for rollback; remove obsolete ones under an explicit retention policy.
It does not start an inactive server. On a new installation, authorize
`systemctl start openbao`, then run the readiness check before initialization.

`certbot.timer` owns renewal. Certbot persists the deploy hook with the lineage;
check `/etc/letsencrypt/renewal/openbao.conf` locally. Successful renewal signals
only `SIGHUP`, never restart: OpenBao 2.7.2 reloads the certificate without resealing.
No unseal shares or OpenBao token are needed. Do not substitute a restart hook.

### Migrate The Initialized HTTP Instance

There are no existing HTTP clients, so cut over directly on port 8200 without
a parallel plaintext listener. Run persistent plans only from canonical `main`
in `/home/alex/sourcecode/homelab`, using the one established production state.
First confirm state ownership and resource identities; do not initialize a second
state or accept guest/data-volume replacement. Plans and live actions need
separate authorization.

1. Confirm independent unseal-share access, recovery credentials, current
   initialized/unsealed health and the existing data-volume attachment. Securely
   retain current configuration and a supported Raft snapshot where available;
   this change does not establish a proven backup/restore system.
2. Install only the Debian ACME packages on the existing guest; do not rerun
   cloud-init or `install.sh`. Stage the reviewed deployment/readiness scripts,
   expiry units and `/etc/openbao/acme-domain` using their template paths and
   permissions. The domain file must be `root:openbao`, `0640`. Create
   `/etc/openbao/tls` as `root:openbao`, `0750`, and `/etc/openbao-acme` as
   `root:root`, `0700`. Add the reviewed certificate conditions to the existing
   hardening drop-in without removing its other protections.
3. Enroll the credential and certificate as above while HTTP remains available.
   The hook may send HUP to the current HTTP process; this does not enable TLS.
   Verify the staged files and native TLS configuration before the downtime window.
4. In the agreed window, install the rendered `openbao.hcl` with the HTTPS API
   address and TLS listener, preserving the existing Raft path and all hardening.
   Run `systemctl daemon-reload`, enable `certbot.timer`, then authorize one
   `systemctl restart openbao`. This restart seals the initialized server.
5. Verify HTTPS from the guest and an intended client, manually unseal over
   verified HTTPS, and confirm prior initialized data and authenticated access.
   Confirm HTTP no longer serves API requests. Never use `BAO_SKIP_VERIFY` or
   `curl -k`. Reconcile reviewed cloud-init metadata without assuming it ran.

Before cutover, rollback means leaving the HTTP config untouched and disabling
the new timers if needed. After cutover, prefer fixing TLS while retaining data.
If the operator explicitly accepts temporary plaintext again, restore the saved
HTTP configuration, restart and manually unseal; never reinitialize or roll back
Raft data. Keep administrative traffic local during such an exception.

### Verify Renewal And Watch Expiry

With explicit authorization for staging DNS writes, test:

```bash
certbot renew --cert-name openbao --dry-run --run-deploy-hooks
systemctl start openbao-certificate-expiry.service
systemctl status certbot.timer openbao-certificate-expiry.timer
journalctl -u certbot.service -u openbao-certificate-expiry.service --no-pager
```

Certbot's dry-run deploy hook uses the current live certificate, not an untrusted
staging certificate. This tests DNS authorization and hook execution, not a new
production leaf. A separately authorized real renewal must show a changed served
certificate with unchanged OpenBao PID, initialized/unsealed state and scoped
authenticated access. Also repeat verification after an authorized guest reboot
and manual unseal; offline tests are not this live acceptance evidence.

The daily expiry unit fails on untrusted/wrong-host TLS, connection failure,
served/deployed mismatch, or expiry within fourteen days. Renewal failures are
visible in `certbot.service` status/journal and protected Certbot logs; inspect
them locally rather than publishing credentials or deployment details. Check
`systemctl --failed` and these journals through the existing operational routine.
No external paging integration is installed. On failure, fix DNS credentials or
connectivity, rerun renewal and verify the served certificate. If publication
succeeded but HUP failed, rerun the hook with
`RENEWED_LINEAGE=/etc/letsencrypt/live/openbao`; do not restart to hide the failure.
For a bad generation, atomically repoint `current` to the retained valid pair,
send HUP, and verify served TLS and health again.

## Initialize Once And Unseal Manually

Choose the Shamir share count and threshold with the operator before
initialization. Store shares securely outside this server and outside OpenBao,
Git, OpenTofu, cloud-init, logs, and issue discussions. Keep a recoverable copy
outside Micro Node's failure domain. The defaults are five shares with a
threshold of three; they are not an automatically selected custody policy here.

Run these commands yourself in a private interactive terminal, not an agent
transcript. Use the certificate's private DNS name and normal system trust:

```bash
export BAO_ADDR='https://<private-service-fqdn>:8200'
bao status
bao operator init -key-shares='<share-count>' -key-threshold='<threshold>'
bao operator unseal
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

[Micro Node]: ../../hosts/micro-node/README.md
