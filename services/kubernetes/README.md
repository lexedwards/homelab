# Kubernetes

This OpenTofu root defines the Rocky Linux 10 amd64 RKE2 control-plane VM on
`compute`, with one colocated etcd member and RKE2-managed Cilium, and an optional
worker on each physical host. [Worker enrollment and runtime operations][workers]
are separate from infrastructure apply. VLAN service pools, application policy,
NFS storage and OpenBao workload-secret delivery are not deployed by this root.
Implementation context and qualification gates
remain in ALE-27–32; durable rationale is in the [ADRs][adrs].

[Workload network policy](NETWORK-POLICY.md) provides an explicitly scoped
namespace baseline, synthetic examples and bounded direct-peer checks. It is not
automatically applied by infrastructure provisioning.

[Service exposure](SERVICE-EXPOSURE.md) describes opt-in private Cilium IPAM/L2
outputs, the native RKE2 chart lifecycle and client-side qualification. Rendering
the outputs does not deploy them or authorize a shared-datapath rollout.

[Retained NFS storage](NFS.md) provides a pinned worker-only CSI chart and opt-in
private StorageClass/qualification outputs. TrueNAS ownership, client restrictions,
quota and backups remain an explicit operator boundary; local checks do not prove
real-backend compatibility.

[Mounted-secret authentication](SECRETS.md) prepares private OpenBao Kubernetes-auth
and exact service enrollment without stored reviewer credentials, secret values
or network access. It does not install the CSI/provider stack or authorize live
OpenBao changes.

**Validation is local evidence, not deployment evidence.** First-boot and restart
acceptance is recorded separately in ALE-28.

## Dependencies

- Reviewed Rocky template, image provenance and a supported full-clone path;
  this root does not own or update the image catalogue.
- Available guest ID, disk capacity, a snippets-capable datastore and tagged
  primary bridge on `compute`.
- DHCP on the primary VLAN. A reservation is not needed before initial deployment;
  reserve the observed IP/MAC pair afterwards, before normal use or maintenance.
- DHCP-provided DNS must resolve the private API name without cluster DNS.
- Existing Technitium zone and service-owned API/worker A records that are not
  already owned elsewhere. Optional worker PTR ownership needs an approved
  existing reverse zone. The API name stays stable through future HA expansion.
- OpenTofu 1.9+, Python 3 with PyYAML, and yamllint. Providers are pinned by the
  lock file. The Python checks parse authored Kubernetes manifests with PyYAML.
- Scoped Proxmox and DNS API authentication over verified HTTPS, and an approved
  node SSH identity loaded into the local SSH agent for snippet upload.

## Local preparation

```bash
cp terraform.tfvars.example terraform.tfvars
chmod 600 terraform.tfvars
make init
make validate
```

Fill the commented required inputs privately before an online operation. The
example deliberately contains no working guest IDs, VLANs, hostnames, addresses,
datastore names, usernames or SSH keys. Optional sizing and pinned package values
are declared in `variables.tf`; all other deployment choices are required inputs.
Use ignored tfvars for stable configuration, or `TF_VAR_...` for declared inputs.
Automatically loaded tfvars take precedence over environment-supplied root inputs.

Authentication uses provider-native `PROXMOX_VE_API_TOKEN` and
`TECHNITIUM_API_TOKEN`; do not put token literals in command history or tfvars.
The Proxmox provider uses the SSH agent, not a private-key file variable. The
Technitium provider enforces `skip_tls_verify = false`; private CA trust must be
configured through its supported trust environment. Proxmox verification is also
on unless a separately approved exception explicitly overrides it.

`make validate` runs format/schema checks and plan/render tests
with **both providers mocked**, readiness-CLI tests with a fake API command,
credential-boundary/enrollment checks with mocked SSH, user-data/network-data
and platform YAML lint, and shell syntax checks. These checks do not
exercise RPM installation, kernel boot or SELinux policy. No infrastructure is
created or contacted. Init downloads providers but does not plan or deploy it.

OpenTofu's VM mock does not populate the computed MAC inside the configured NIC.
The VM-focused worker checks override the DNS module; separate module checks feed
synthetic guest-agent observations through real MAC/address selection and mocked
DNS resources. They verify both A/PTR plans and rejection paths, not actual lease
discovery or authenticated DNS publication.

## Reviewed plan and deployment

Only after separate authorization, verify template/key fingerprints, current
guest-ID availability, snippets storage and DNS record ownership. Proxmox always
manages the NIC MAC; this root provides no MAC override, generated-MAC convention
or node-IP input.
Use DHCP and reserve the observed lease upstream; do not guess a free IP.
The initial DNS target is unknown until the guest agent reports its DHCP lease.

```bash
make plan
tofu show deployment.tfplan
make apply
```

These are online operations, not validation commands. Inspect the saved plan
privately in this workflow before applying it; configuration changes invalidate
that review. Apply only the inspected, unchanged plan. Keep state, plans, rendered
cloud-init and local inputs protected and securely backed up. Sensitive markings
redact normal output; they do not encrypt stored data.

Run persistent plans/applies only from the canonical checkout on `main`, using
its existing default-workspace state. Feature worktrees are for development and
mocked tests, not a second deployment state.

The server and future worker resources belong to one root/state with separate
resource groups and operational procedures. The explicit server resource uses
the full-control VM clone API because it must own cloud-init, protection,
guest-agent, UEFI/Q35, Secure Boot and on-boot settings. Do not switch resource
models or import a different owner without a reviewed migration.

## First boot and readiness

`cloud-init/network-data.yaml` supplies complete version-2 network-data through
`initialization.network_data_file_id`. It enables DHCP on `ens18` without static
addresses, routes, nameservers or MAC matching. NetworkManager accepts DNS from
DHCP; Proxmox's host-resolver defaults are not injected into this custom document.
The generated `ip_config` path is deliberately omitted. This is separate from
user-data, not a post-boot command or a helper that rewrites network settings.

`ens18` is the primary VirtIO interface in the reviewed Rocky/Q35 single-NIC
layout. Revalidate this mapping if the image or PCI/NIC layout changes. Workers
use separate primary network-data and a native secondary NetworkManager profile;
see the worker runbook for the renderer limitation and required reboot boundary.

Cloud-init creates the approved non-root administrator, replaces that user's
authorized-key file with the reviewed operator keys, disables root/password SSH
and installs/enables the QEMU guest agent. It writes the API identity,
internal CIDRs, server taint and managed-Cilium configuration before
starting the cluster. No Kubernetes token, kubeconfig or private certificate is
supplied to OpenTofu/cloud-init; initial RKE2 startup generates them in the guest.

The root-only installer:

1. Requires Rocky 10 amd64 and SELinux enforcing; refuses an existing etcd data
   directory rather than treating first boot as an upgrade/restore tool.
2. Installs the distribution kernel/module prerequisites and exact RKE2
   server/common/SELinux version-release packages from persistent EL10 repos.
3. Downloads the Rancher signing key over HTTPS and checks a pinned SHA-256 before
   import; both package and repository signature checks remain enabled. The key's
   reviewed primary fingerprint is `C8CFF216455126E9B9C918BE925EA29AE257814A`.
   Its pinned digest was obtained from the HTTPS publisher; this is not an
   independent release-signature verification. A key rotation fails closed and
   needs an explicit reviewed digest update.
4. Writes persistent module-loading and forwarding settings, disables guest swap,
   preserves SELinux labels and excludes Cilium interfaces from NetworkManager
   management. It does not load newly installed modules into the template's old
   running kernel, or disable SELinux or the guest firewall.
5. Enables the RKE2 server and creates an installation marker only on success.
   The systemd unit requires that marker. Cloud-init then reboots the guest into
   the installed kernel. RKE2 first starts on the subsequent boot; its preflight
   rejects non-enforcing mode or active swap, loads the required modules for the
   running kernel, and applies the Kubernetes sysctl file. A missing module or
   failed sysctl causes startup to fail rather than continuing without it.

The repository excludes RKE2 packages from ordinary DNF updates; only the explicit
installer command clears those two repository exclusions while selecting exact
versions. This is not an upgrade procedure: use the later reviewed server-first
upgrade workflow, and never rerun first-boot provisioning against useful etcd data.
OS kernel updates remain distinct and can require planned guest reboots.

### Reserve the first lease after deployment

Inspect `tofu output -json control_plane_dhcp_lease` locally after authorized apply.
This explicitly reveals the private primary-NIC IP/MAC pair; keep it out of Git,
tickets and public logs. Create the matching UniFi fixed DHCP reservation before
accepting workloads or restarting/maintaining the server. Keep the existing IP;
do not deliberately move the node as part of reservation creation.

RKE2 discovers the node IP through its native address selection. No helper
rewrites configuration, records an IP/MAC identity file or checks that pair on
restart. Stable addressing is an upstream DHCP responsibility: if the lease
changes, restore the original reservation and investigate before maintenance.
Worker enrollment additionally verifies primary-interface/address selection;
single-NIC server acceptance does not establish dual-NIC behavior.

OpenTofu selects the guest-agent address by the managed primary NIC's MAC, not
the first non-loopback/pod address, and publishes API DNS after VM address discovery.
The API's stable DNS name remains in initial TLS SANs. Cilium uses that name on
TCP 6443, not a rewritten node IP or the Kubernetes Service IP. The pinned
RKE2-managed Cilium chart has no API-host default suitable for kube-proxy-free
bootstrap. Its agent and operator use host networking and host DNS, so the
external DNS record must resolve from the guest without CoreDNS/Cilium. The VM
can report its DHCP address and RKE2 can start its API before Cilium is ready;
DNS publication therefore does not depend on CNI readiness. Cilium may retry
while DNS propagation completes. Verify this ordering during live qualification.
With multiple usable addresses on the primary NIC, planning/apply fails rather
than choosing one arbitrarily. DHCP discovery is not proof that a reservation is
created, the IP cannot change, or cloud-init/cluster startup has completed.

The guest-agent address output is sensitive and is **not** an API readiness claim.
After separately authorized deployment/reboot, transfer the read-only checker to
the guest and run it locally with protected kubeconfig access:

```text
sudo python3 check-control-plane.py --node-name <server-node-name> \
  --expected-version <reviewed-rke2-version> \
  --api-server https://<stable-api-name>:6443
```

The checker defaults to a 300-second total observation bound and checks API
readiness through the stable DNS/TLS identity, exactly one control-plane node,
its expected Kubernetes version and NoSchedule taint, and Cilium rollout. It does
not print API responses/command stderr or weaken certificate verification.
`--timeout` accepts a positive number up to 900 seconds; `--kubectl` and
`--kubeconfig` override the in-guest defaults. Exit 0 means those checks passed;
nonzero means failure/timeout. It does **not** prove etcd member count, workload
scheduling rejection, certificate renewal or application availability.

Before accepting bootstrap, separately inspect actual single-member etcd
membership using the installed RKE2 version's documented etcd administration
procedure, and run the authorized untolerated-workload scheduling rejection
check. A Ready API or one static etcd pod is not membership evidence. Record those
results against the reviewed revision; do not mark ALE-28 complete based solely
on local tests or this checker.

## Ownership and network boundary

This root owns its API A record, worker A records and explicitly enabled worker
PTR records, not DNS zones. Each A record points to the node's observed primary
DHCP address, never a workload service IP. Worker records use `api_dns.zone` and
`api_dns.ttl`; see the [worker runbook][workers] for optional reverse-zone ownership
and existing-record imports. `overwrite = false` preserves other RRset members;
it does not detect conflicting records or competing state/DHCP owners. The
private API FQDN remains in RKE2's initial TLS SAN list. DHCP reservations stay
upstream; discovery and DNS publication do not create or prove their uniqueness.

RKE2 alone owns the managed Cilium chart. Its pre-bootstrap `HelmChartConfig`
selects kube-proxy replacement, VXLAN, Kubernetes IPAM and host-namespace-only
socket load balancing for later Kata compatibility. The single server gets an
explicit control-plane NoSchedule taint while critical components can tolerate it.
Managed ingress options are disabled; no competing CNI, kube-proxy or application
ingress controller is installed. This slice creates no LoadBalancer pools or L2
announcement policy and does not attach ordinary pods directly to LAN VLANs.

Keep VM infrastructure and workload lifecycle separate: this root authors the
minimum bootstrap configuration; subsequent platform manifests are a separately
invoked reviewed lifecycle, not an imperative remote-exec provisioner or an
apply-everything Kubernetes provider. Changing cloud-init does not rerun it on an
existing VM. Apply deliberate post-bootstrap configuration changes through their
reviewed operating procedure instead of assuming snippet upload updated the guest.

| Dependency | Required path |
| --- | --- |
| Administrators | SSH TCP 22; Kubernetes API TCP 6443 through the stable private name |
| Future workers/servers | API TCP 6443 and supervisor/registration TCP 9345 |
| Node/CNI communication | RKE2/Cilium documented node paths, including kubelet TCP 10250 and VXLAN UDP 8472 where needed |
| Additional etcd servers later | Server-only peer/client TCP 2380/2379; not public/workload access |
| First-boot outbound | Approved DNS/NTP, distribution/Rancher HTTPS package repos and release/container registries |

Use existing routing/firewall ownership; do not expose these management ports to
untrusted clients. First-boot failure must not be repaired by disabling firewall
or SELinux globally. Service exposure/policy and cross-worker verification are
later slices.

## Credentials, data and recovery

After initial bootstrap, protect the generated secure server token through the
reviewed out-of-band enrollment procedure: external OpenBao over verified HTTPS
plus an independently accessible Proton Pass recovery copy. Do not print it in
normal outputs, paste it into tickets, supply it as an OpenTofu variable or rely
on an in-cluster controller. Retain the token material associated with retained
snapshots; the newest token is not assumed sufficient for every recovery point.
OpenBao HTTPS delivery precedes real secret enrollment. This root does not yet
configure OpenBao, snapshots, RustFS credentials, NFS or alerts.

Irreplaceable control-plane data, bootstrap/certificate material and the token
live on the VM OS disk. VM protection prevents ordinary destroy, not storage
failure or data loss. Protection must be deliberately disabled in a reviewed
change before destroy/replacement. VM destruction can delete its managed OS,
EFI and cloud-init disks; it is not a recovery method once data matters.
The source template remains separately owned; unreferenced disks are not opted
into blanket deletion. Back up OpenTofu state independently and protect the
corresponding RKE2 recovery material.

The approved later backup policy is six-hour snapshots retained fourteen days
in a dedicated off-node bucket, verified TLS and independent credential custody.
Approximately four hours is a planning recovery target, not an SLA or tested
restore duration. Until backups and isolated restore are implemented/verified,
do not describe this single-node server as backed up or production-recoverable.
Application-volume backup, storage HA and notification decisions are separate.

## Restart, expansion and troubleshooting

Expect API/scheduling/reconciliation downtime for a single-server restart or
`compute` outage. Enablement persists across boot, but actual restart/rejoin must
still be verified against this implementation without reconstructing etcd.
Initial bootstrap failure may recreate only reviewed newly owned resources;
after useful data exists, use an authorized isolated restore, not VM deletion,
`cluster-reset` against production or an unreviewed package downgrade.

### Recovering an earlier failed first boot

Changing the cloud-init snippet does not repair an existing guest. Plan recovery
separately from merging these changes, preserving the VM, its current MAC/lease
and canonical state. The NIC MAC is computed by the provider, not configured by
this root; still reject an unexpected MAC change or VM replacement in the next
reviewed plan. Remove any old `control_plane.mac_address` and
`control_plane.ipv4_address` entries from local inputs; neither is consumed.

Adding or changing custom network-data can propose VM replacement through the
provider's cloud-init lifecycle. It does not update an existing guest's active
NetworkManager profile. Review a fresh canonical-main saved plan and its data,
downtime and identity implications before authorizing rollout; do not recreate
an initialized datastore without explicit approval for downtime and deletion of
the current guest data.

For a failure before RKE2 installation, first confirm there is no useful etcd
data and that RKE2 is stopped. An authorized in-place recovery must update the
installer, preflight and rendered RKE2/Cilium configuration together, removing
the old helper and its identity files only after their callers are removed.
The installer remains first-boot-only: do not rerun cloud-init or use it to
upgrade an initialized datastore. Inspect installation success, explicitly
authorize the kernel reboot, then qualify API/DNS/Cilium, etcd membership,
scheduling isolation and restart/rejoin. Neither a successful apply nor these
local tests establish that the existing failed guest has recovered.

### HA expansion

Future HA preserves the API name behind a frontend independent of Cilium's
workload announcements, supporting TCP 6443/9345 and the existing certificate
identity. Back up data/associated credentials, review failure-domain placement,
and join two additional server/etcd members sequentially through RKE2's supported
registration path. A permanent two-member etcd cluster is not fault tolerant;
three VMs across two hosts are not three independent host-failure domains. This
slice provisions no extra server/frontend, and later code must preserve
the existing server resource identity rather than rebuild the cluster to expand.

### Troubleshooting

For failures inspect `cloud-init status --long`, protected cloud-init logs,
`systemctl status rke2-server`, and `journalctl -u rke2-server` in the guest.
Check install-marker/reboot completion, repository/key/RPM versions, SELinux AVCs,
DHCP/MAC/address correspondence and the managed Cilium Helm status. These logs
may contain protected information; do not publish them wholesale. Do not rerun
cloud-init or modify image-catalogue state as a troubleshooting shortcut.

[adrs]: ../../docs/adrs/
[workers]: WORKERS.md
