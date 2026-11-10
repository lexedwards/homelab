# Kubernetes Prerequisite Findings and Handoff

**Status: approved architecture with qualification gates still open.** This is
the sanitized ALE-27 investigation handoff, not a deployed-system runbook.
Findings are current to 2026-11-10. No production Kubernetes resources are created
by this documentation change, and ALE-27 is not complete merely because a PR exists.

## Selected design

| Concern | Decision |
| --- | --- |
| Topology | One RKE2 server/etcd VM on `compute`; one worker per x86 host; ordinary applications excluded from the server |
| Platform | Rocky Linux 10 amd64, pinned signed RPM installation, SELinux enforcing |
| Node sizes | Server: 2 vCPU / 4 GiB / 32-GiB OS disk; each worker: 4 vCPU / 8 GiB / 64-GiB OS disk |
| Ordinary / isolated runtime | `runc` default; explicit stock Kata Rust `clh-runtime-rs` / Cloud Hypervisor RuntimeClass, without fallback |
| Node network | Primary node/API VLAN with fixed DHCP reservations; workers also attach to the separate workload-service VLAN |
| Service exposure | Cilium LoadBalancer pools outside DHCP; 32 approved addresses per VLAN, separate from pod and internal Service CIDRs |
| Persistent data | Dedicated TrueNAS NFS dataset/export, 500-GiB aggregate quota, NFS CSI, `Retain` |
| Workload secrets | External OpenBao, verified HTTPS, scoped Kubernetes authentication, CSI files, Secret synchronization disabled |
| Control-plane recovery | Dedicated RustFS bucket; six-hour snapshots, fourteen-day retention; approximately four-hour planning target |
| Credential custody | External OpenBao plus independent protected Proton Pass recovery copies for server token and scoped backup credential |

The private operator record contains actual names, addresses, reservations,
template/storage references, export and bucket locators. Do not copy that record,
tfvars, plans, state, keys or raw proof logs into this repository.

Architecture rationale is captured separately:

- [Topology and lifecycle][topology]
- [Isolated runtime][runtime]
- [NFS persistence][storage]
- [File-mounted secrets and accepted provider-label risk][secrets]
- [Recovery and credential custody][recovery]

## Evidence and its limits

The authorized disposable proofs ran on fresh Rocky guests. They used synthetic
NFS/OpenBao data, bounded duration, host-memory safeguards and pre-existing-guest
status checks. Cleanup receipts record removal of owned VMs, disks and seed files;
no production backend or physical-host configuration change was part of those
proofs. Later operator-reported DHCP changes are separate from proof execution.

Native configurations, chart payloads, process/KVM descriptors, audit events,
functional results and cleanup records remain in checksummed private archives.
The reports below are summarized, not uploaded: they include private deployment
metadata. SHA-256 values identify the retained reports; they are not vendor
signatures, public raw evidence or independent security approval.

| Evidence set | Scope | Retained report SHA-256 |
| --- | --- | --- |
| AMD VMM comparison, 2026-11-09 | Separate stock Cloud Hypervisor and Dragonball installs | `c701b56406ffa48c98352d1b039320ff1432d6f4238ba6f72bac5ae25ab4106a` |
| Intel runtime/NFS/auth, 2026-11-09 | Selected runtime, no fallback, NFS lifecycle/Retain, initial provider failure | `9b735462acf836c376eb8bd172f976cdac6a9513d298fae564dbca56fff7b172` |
| Intel provider label, 2026-11-09 | Scoped label reversal, secret delivery/rotation/failure/reboot | `fe0902ad9f78dee0864d9fd85be694accd5b382f67c23b6c2b847adcf19229b8` |

### Observed version baseline

These are proof versions, not a claim of upstream certification or an instruction
to follow a mutable latest release. Implementation must retain immutable chart
payload hashes and the reviewed RPM/repository/key contract, and requalify any
changed component set.

| Component | Observed version |
| --- | --- |
| Rocky guest / worker kernel | 10.2 / `6.12.0-211.74.1.el10_2.x86_64` |
| RKE2 / node-reported containerd | `v1.36.6+rke2r1` / `2.3.7-k3s1` |
| RKE2-managed Cilium | `1.20.4` |
| Kata Rust / Cloud Hypervisor / isolated kernel | `4.3.1` / `54.0` / `6.18.56` |
| NFS CSI | `4.13.6` |
| Secrets Store CSI Driver | `1.6.2` |
| OpenBao provider / provider chart | `2.0.3` / `0.30.7` |
| Synthetic OpenBao server | `2.7.2` |

Rocky compatibility observations are distinct from an enterprise support
entitlement. RKE2 documents additional kernel-module prerequisites for RHEL 10
derivatives; do not assume a successful older guest boot satisfies them.

### Runtime and networking

- Stock Cloud Hypervisor ran actual KVM-backed pods on both AMD and Intel under
  SELinux enforcing. The VMM and external virtiofsd showed `container_kvm_t` with
  pod-specific MCS labels; VMM seccomp and VM/vCPU descriptors were observed.
- Ordinary pods kept `runc`; isolated guest kernels differed from worker kernels.
  A deliberately missing handler produced an explicit failure without a running
  container or fallback.
- DNS, Services, HTTP/payload and Cilium deny/explicit-allow paths passed. The
  Intel test used direct peers for the policy comparison. These tests do not
  qualify dual-VLAN LoadBalancer advertisement or cross-worker traffic.
- Agent restart passed. The earlier AMD undrained Cloud Hypervisor reboot took
  roughly 342 seconds of observation after the request. The cause remains
  unresolved. Later planned, drained Intel reboots passed; they do not repair or
  explain the undrained case.
- Host-side Kata API/virtio-fs sockets were observed without pod MCS categories.
  Distinct VMM labels are not a complete cross-sandbox socket-isolation proof.

Cloud Hypervisor was selected instead of maintaining an experimental Firecracker
repair or using Dragonball's embedded VMM boundary. The Firecracker issue draft,
collector output and patch evidence remain private and unpublished; this PR does
not deliver or publish those artifacts.

### Persistent volumes

NFS CSI dynamically provisioned an RWX claim from a synthetic NFSv4.1 export.
Non-root ordinary/Kata consumers shared data through NFS/virtio-fs respectively.
An initial GID mismatch was corrected on the dedicated test export while keeping
root-squash; no global relaxation, world-writable mode or permissive worker was used.

Controller-managed consumers reattached after planned worker drain/reboot cycles.
A separately written witness that startup did not rewrite survived unchanged.
Deleting the PVC left the same PV `Released` with `Retain` and unchanged backing
data. This proves neither production TrueNAS ACLs nor automatic claim recovery,
application-consistent backups or storage HA.

### Workload secrets and the label exception

Short-lived pod JWT authentication over verified test TLS passed scoped access
and wrong-path/service-account/audience rejection. The initial stock provider
failed socket creation because its host directory was `kubernetes_file_t:s0`.

A fresh Intel proof applied a persistent `container_file_t:s0` override scoped to
`/etc/kubernetes/secrets-store-csi-providers(/.*)?`, then applied the mapping with
`restorecon`. Removing the override restored provider denials; restoring it
restored delivery. Chart paths, Unix directory ownership/mode and provider
security settings stayed unchanged. No broad policy module or permissive domain
was added. The main Secrets Store CSI driver remained privileged; the provider
remained nonprivileged UID 0 with zero effective capabilities, NoNewPrivs and seccomp.

Ordinary/Kata consumers, including UID/GID 1000 consumers, read resolved mode-0444
files on read-only mounts. Both mounted files rotated without consumer restart;
provider replacement and subsequent rotation passed. Forbidden-path mounts were
rejected. Sealing synthetic OpenBao blocked fresh mounts while existing mounts
retained their values; pending mounts recovered after unseal. Planned drained
worker reboot restored labels, provider and consumers without manual relabel.
Synchronization remained disabled, with no Secrets in the workload namespace;
that is not a claim that the cluster contains no Secrets.

The first proof manifest used an incorrect quoted file-mode value; it was fixed
before successful delivery and the label reversal comparison. The default-label
control helper timed out, but native AVCs/provider logs and non-running consumers
independently establish the failure. Post-reboot audit snapshots include earlier
denials because the audit offset was ephemeral; do not interpret them as a clean
post-fix interval or claim every worker AVC disappeared.

The operator accepted the shared container-data label risk for the initial
homelab, assuming restricted hostPath/privileged execution and scoped OpenBao
roles. This does not waive Kata runtime socket isolation. File rotation does not
establish application reload; sealed-backend behavior does not cover every
network outage, timeout or reviewer-token renewal failure.

## Implementation contract

This section is the proposed handoff for review, not installed configuration.

### Infrastructure, bootstrap and ownership

OpenTofu owns VM infrastructure and safe first-boot configuration. Review full
clones of the existing, separately owned Rocky template; do not replace or adopt
its state incidentally. State records a publisher build/checksum, not a fresh
hash of current template bytes. Reconcile stale image-catalogue documentation
with its owner before relying on it; do not run a catalogue apply to fix prose.

Use persistent signed EL10 repositories and pinned RKE2 RPMs via `dnf`, including
required kernel modules/SELinux policy. Do not pipe a remote installer into a shell.
Retain UEFI/Q35, host CPU exposure, usable nested KVM and enabled-at-boot RKE2
services. Review actual operator key fingerprints rather than blindly inheriting
every template SSH key. No private SSH keys go into guests or cloud-init.

The Kubernetes root owns its service DNS record, following the existing
[DNS ownership decision][dns-ownership]. The DNS root retains zone ownership.
Keep exact zone/FQDN values private and include the stable API name in initial
TLS SANs. The initial name resolves to the reserved server address, not a Cilium
application-service IP. API traffic uses TCP 6443; agent/server registration uses
TCP 9345. Protect kubeconfig and certificate material as credentials.

Follow [OpenBao ownership][bao-ownership]: shared engines/auth backends have one
platform owner; Kubernetes-specific roles/policies belong to the service owner.
Secret-value enrollment is separate. Root-only guest token/backup-credential
files must be supplied through reviewed out-of-band handling, not OpenTofu
arguments/state, saved plans, cloud-init or printed command output.

### Cluster configuration and network ownership

Use repository-owned manifests through a separately invoked reviewed Kubernetes
configuration lifecycle, not an apply-everything side effect of VM creation.
The proposed platform mechanism is RKE2 `HelmChart`/`HelmChartConfig` plus manifests;
there is no hidden GitOps controller prerequisite.

RKE2 owns its managed Cilium chart. The proof used kube-proxy disabled and Cilium
kube-proxy replacement, VXLAN tunneling, Kubernetes IPAM and host-namespace-only
socket load balancing for Kata compatibility. Carry that as the candidate
configuration; verify effective values and API reachability before promotion.
Do not introduce a competing CNI, kube-proxy installer or second chart owner.
Managed ingress/ServiceLB components must not compete for the selected ownership;
application ingress choice is separate from this prerequisite investigation.

Freeze a unique MAC per NIC in reviewed private inputs before creating fixed DHCP
reservations. Reserve three primary NIC addresses plus two worker secondary NIC
addresses. Keep one default route and explicit RKE2 node/API identity on the
primary VLAN. Bind Cilium announcements to intended worker interfaces/pools;
do not advertise either pool through every interface indiscriminately.

The operator confirmed both LAN subnets, DHCP changes/exclusions, tagged LAG
uplinks and existing isolation of the untrusted client VLAN. These are
operator-confirmed inputs, not new live firewall tests. Check outstanding leases,
static conflicts and final NIC configuration before advertisement. Do not reopen
firewall redesign as a new prerequisite or change physical hosts to make the test pass.
Approved pod/Service CIDRs are separate private inputs; the earlier synthetic
proof ranges must not overwrite them. A LAN pool IP normally serves a
LoadBalancer Service, not each pod, and does not imply public exposure.

### Runtime, storage and secret handoff

Install only the selected stock runtime on both workers, without changing the
ordinary default. Enable RuntimeClass scheduling constraints only after actual
KVM/handler revalidation. Use persistent supported containerd configuration;
do not edit generated configuration that RKE2 will overwrite.

Confirm the new TrueNAS child dataset's full pool-qualified name and real mount
path, its quota/snapshot semantics and root-squash mapping before export. Restrict
clients to worker reservations. Validate UID/GID/ACLs and NFS CSI behavior without
copying synthetic anonymous-group settings blindly. Keep `Retain` explicit and
require deliberate recovery/cleanup of released data. Dataset usage alerts have
not been selected or configured by this handoff.

Install provider-only OpenBao chart values: no duplicate OpenBao server, injector
or agent. Keep Secret synchronization disabled and use verified HTTPS. Make the
scoped persistent label rule part of worker provisioning, test new sockets after
provider replacement and review effective security contexts rather than assuming
a root chown/init-container recipe is present in every packaging variant.

Before real secrets, define Kubernetes API trust, role/token audiences and
lifetimes, TokenReview permissions and reviewer-credential renewal. Test ordinary
and Kata file delivery on the deployed configuration, rotation/reload and outage
behavior with synthetic data first. OpenBao's production HTTPS work is a prerequisite
for transmitting real credentials, not for drafting VM infrastructure.

### Recovery, expansion and rollback

Use a dedicated bucket-scoped RustFS credential for snapshot upload/list/read/
retention cleanup, not observability's credential or certificate-verification
bypass. Verified TLS and independent access to both backup credentials and the
snapshot-associated server token are prerequisites for relying on backups.

Future HA retains the stable API identity behind a frontend independent of Cilium.
Back up and retain matching recovery material before membership changes, establish
the frontend's 6443/9345 paths and certificate coverage, and add servers sequentially
using the supported RKE2 registration flow until there are three etcd members.
Review placement across physical failure domains; three VMs on two hosts are not
three independent host-failure domains. Do not claim this design is a rehearsed
membership migration or restore.

For initial bootstrap failure, stop before accepting workloads and recreate only
reviewed, owned disposable/new resources. Once the datastore or application data
matters, do not treat VM destruction, image rollback or an unreviewed package
downgrade as recovery. The later lifecycle work owns isolated snapshot restore,
server-first upgrades, drain/rejoin, pause/rollback criteria and loss-of-host tests.
Planned `compute` maintenance drains its worker while the API is available, then
accepts API downtime; loss of `store` also removes its storage backend.

## Remaining gates and traceability

The completion gate is reviewed findings/ADRs merged after relevant checks.
There is no new provisioning authorization in this document. Public tracking
contains status and constraints; private records contain actual deployment values.

| ALE-27 criterion | Evidence / handoff | Remaining gate |
| --- | --- | --- |
| AC1: host/image/identity prerequisites | Operator-approved sizes, VM/image/storage selections; both-vendor disposable clones; read-only bridge/storage inventory | Final MAC/reserved-address manifest and image provenance review before production plan; physical storage topology was not independently verified |
| AC2: amd64 compatibility/security | Exact baseline above; stock runtime on both vendors; synthetic driver integration | Reviewer approval of support/version contract; unresolved runtime security boundary below |
| AC3: bootstrap/ownership/stable identity | API convention approved; explicit ownership, installation, token and rollback boundary above | Review this proposed manifest/Helm handoff and final private endpoint/reservations |
| AC4: VLANs/pools/ownership | Operator-approved pools outside reported DHCP, bridge/LAG evidence, existing untrusted-VLAN isolation | Conflict/lease checks and deployed dual-NIC/advertisement qualification; not a new firewall redesign |
| AC5: credential lifecycle | External OpenBao plus independent Proton Pass custody approved; scoped synthetic auth passed | Private enrollment references, production API/reviewer lifecycle, real HTTPS qualification before credentials |
| AC6: sizing/configuration/backups | Sizes, snapshot policy, custody and recovery objective approved; boundaries above | Reviewed handoff; backup/restore execution belongs to later lifecycle work |
| AC7: isolated runtime interfaces | Both-vendor KVM/network evidence, no fallback, Intel NFS/secret volumes and planned maintenance | Explicit disposition of undrained shutdown and runtime socket/MCS gaps; AMD CSI and cross-worker paths not proved |
| AC8: future HA design | Stable identity, independent frontend, sequential three-member expansion and recovery boundary above | Design review; no HA deployment or initial ARM proof required |

### Disposition required before calling ALE-27 complete

The slow undrained runtime shutdown and incomplete Kata host-socket/MCS isolation
remain specific qualification gaps, not accepted by the provider-label decision.
Reviewers/operator must approve a bounded qualification plan or explicitly accept
a documented operating restriction/residual risk; this PR does not make that
choice for them. Final private reservations/identity review and the proposed
configuration-owner handoff also remain open. Return concrete blockers rather
than silently marking all prerequisites met or moving acceptance criteria.

Production TrueNAS ACL/export validation, production authentication/reviewer
lifecycle, application reload and worker upgrade/replace checks belong to their
integration/lifecycle stages; synthetic success is supporting evidence, not a
substitute. Keep these gates attached to the dependent operation.

### Tracked dependent and deferred work

| Work | Boundary |
| --- | --- |
| ALE-28 / ALE-29 | Server/worker implementation, final private identities, safe enrollment and deployed qualification |
| ALE-30 / ALE-31 | Network ownership, VLAN service exposure and policy verification |
| ALE-32 | Backup/restore, upgrades/replacement, outage behavior and runtime lifecycle qualification |
| ALE-41 | Production OpenBao verified HTTPS before real credential delivery |
| ALE-42 | Optional dedicated provider SELinux isolation; not an initial deployment/closeout blocker |
| ALE-43 | RustFS verified TLS for observability and backup consumers; required before relying on off-node backups |
| ALE-44 | Explicitly deferred backup alerting decision; not an ALE-27/initial provisioning blocker; no destination or threshold chosen |

## Public source references

These explain upstream contracts; they do not certify this exact combination.
Release-scoped payloads/configurations are retained privately with the proof.

- [RKE2 requirements][rke2-requirements], [installation][rke2-install],
  [advanced configuration][rke2-advanced], [HA][rke2-ha] and [backup/restore][rke2-backup]
- [Kata hypervisors at 4.3.1][kata-hypervisors] and [released chart values][kata-values]
- [NFS CSI at v4.13.6][nfs-driver]
- [OpenBao provider at v2.0.3][bao-provider] and [Helm chart 0.30.7][bao-chart]
- [Secrets Store CSI Driver documentation][secrets-driver]

[topology]: ../adrs/003-kubernetes-topology-and-lifecycle.md
[runtime]: ../adrs/004-kubernetes-isolated-runtime.md
[storage]: ../adrs/005-kubernetes-nfs-persistence.md
[secrets]: ../adrs/006-kubernetes-file-mounted-secrets.md
[recovery]: ../adrs/007-kubernetes-recovery-custody.md
[dns-ownership]: ../adrs/001-technitium-state-ownership.md
[bao-ownership]: ../adrs/002-openbao-service-configuration-ownership.md
[rke2-requirements]: https://docs.rke2.io/install/requirements
[rke2-install]: https://docs.rke2.io/install/methods
[rke2-advanced]: https://docs.rke2.io/advanced
[rke2-ha]: https://docs.rke2.io/install/ha
[rke2-backup]: https://docs.rke2.io/datastore/backup_restore
[kata-hypervisors]: https://github.com/kata-containers/kata-containers/blob/4.3.1/docs/hypervisors.md
[kata-values]: https://github.com/kata-containers/kata-containers/blob/4.3.1/tools/packaging/kata-deploy/helm-chart/kata-deploy/values.yaml
[nfs-driver]: https://github.com/kubernetes-csi/csi-driver/tree/v4.13.6
[bao-provider]: https://github.com/openbao/openbao-csi-provider/tree/v2.0.3
[bao-chart]: https://github.com/openbao/openbao-helm/tree/openbao-0.30.7/charts/openbao
[secrets-driver]: https://secrets-store-csi-driver.sigs.k8s.io/
