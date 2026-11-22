# Kubernetes Lifecycle Runbooks

Use these procedures to prepare a separately authorized maintenance change. They
do not authorize an upgrade, restart, outage, restore or infrastructure apply.
Review the exact targets, versions, observation bounds and recovery decision
before execution. Do one operation at a time.

## Qualification and limits

The initial cluster has one RKE2 server with colocated etcd on `compute`, plus one
worker on each Proxmox host. The control plane is not highly available.

| Area | Recorded position |
| --- | --- |
| Backups | Native off-node upload, independent credential custody, freshness/failure reporting and a natural six-hour timer run verified. |
| Worker maintenance | Replacement and planned drained reboot checks passed; do not repeat them merely to complete documentation. |
| Control-plane recovery | An earlier failed experiment was retired. A later synthetic new-VM native restore preserved cluster identity and an unchanged worker, with a new server Node name. Maintained restore bootstrap and production replacement remain unqualified. |
| Kubeconfig publication | Separate-bucket synthetic OpenBao enrollment, first publication, conditional refresh, administrator download and native timer recovery passed. Production rollout remains a separate operation; see the [artifact procedure](artifacts/README.md). |
| Server-first upgrade and bounded host-loss exercises | Procedures below are unrehearsed, not runtime acceptance evidence. |
| Three-server expansion | Future design only; no extra server or HA frontend is deployed by this runbook. |

Unrehearsed procedures remain unverified. The loose four-hour restore target is
a planning objective; production restoration has not demonstrated that recovery time and
there is no recovery-time SLA.

## Before any maintenance

1. Confirm the approved window, exact guests and expected downtime. Arrange
   independent guest/Proxmox access; do not rely on Kubernetes during API loss.
   Set an observation deadline and a stop/recovery decision for each step.
2. Record a private baseline: node names/UIDs/versions/roles, sole etcd member and
   cluster IDs, API TLS/CA identity, DHCP reservations/MACs, both worker VLAN
   addresses, and service IPs with their announcing workers. Check upstream DNS.
3. Require API readiness, healthy etcd, Ready nodes and converged Cilium/native
   Helm resources. Check capacity, replicas, disruption budgets and local data
   before removing a worker. A PDB or capacity failure stops planned maintenance.
4. Confirm a fresh ready off-node recovery point and its matching independently
   recoverable token using [BACKUP.md][backup]. For an upgrade, take an explicitly
   approved pre-upgrade point outside the scheduled-retirement prefix. Keep the
   snapshot and actual token, not just fingerprints. Unproven restoration remains
   a risk to accept explicitly in the change plan, not an automatic rollback path.
5. Record ordinary and explicit Kata/Cloud Hypervisor workload identities,
   readiness, permitted/denied network paths, and required volume/secret mounts.
   Use owned stateless fixtures for failure tests, not destructive storage tests.
6. Preserve Rocky 10 amd64, enforcing SELinux, default runc, the explicit Kata
   handler without fallback, retained NFS data and service-owned DNS. Secrets
   stay out of source, state/plans, cloud-init, argv and published evidence.

Use the protected kubeconfig and verified stable API endpoint. Useful read-only
baseline checks include:

```bash
kubectl get --raw=/readyz
kubectl get nodes -o wide
kubectl -n kube-system get daemonset cilium
kubectl get pdb -A
```

Keep output private. These commands do not establish etcd health/membership,
actual Kata execution, volume access or L2 advertisement. Use the role-specific
checks in [WORKERS.md][workers], [SERVICE-EXPOSURE.md][exposure],
[NETWORK-POLICY.md][policy], [NFS.md][nfs] and [SECRETS.md][secrets].

Infrastructure plans/applies use canonical `main` and the existing service-owned
state. Inspect a fresh saved plan before any apply. Stop on unexpected VM,
snippet, disk, MAC, DNS or ownership changes. Do not rerun cloud-init or the
first-boot installers on initialized nodes. Do not apply API-dependent runtime
configuration while the API is unavailable.

## Planned worker maintenance

Follow [the worker maintenance/replacement procedure][worker-maintenance] for one
worker at a time. Cordon, then drain evictable workloads with an explicit timeout
and `--ignore-daemonsets`. Do not bypass PDBs, force-delete pods or approve local
data deletion implicitly. DaemonSets and static pods are not proof of a failed
drain; account for them separately.

For a restart, retain the same node UID, MACs and reservations. For replacement,
expect a new node UID and Proxmox-managed MACs; reconcile reservations, DNS and
the old node identity deliberately. Never run duplicate node identities.

Recheck Cilium, both VLANs, persistent runtime configuration, enforcing SELinux
and fresh ordinary/Kata execution before uncordoning. Remove verified Kata
eligibility on failure. If the Kata installer must run, retain its full desired
worker set and review every worker it can restart; narrowing it to one node can
uninstall the peer. Recheck retained volumes and mounted-secret access without
reading or publishing secret values.

Slow undrained shutdown remains distinct from planned drained reboot evidence.
Reaching the observation deadline means stop and inspect shim/VMM/virtio-fs and
guest shutdown state, not force-reset automatically or silently extend the bound.

## Server-first RKE2 upgrade

This is a manual, exact-version RPM upgrade, not an unattended channel update.
Follow [upstream manual upgrade ordering][manual-upgrade] and the target release's
notes. The repository's current baseline is `v1.36.6+rke2r1`; select a target in
the change plan rather than treating this document as a new version pin.

1. Check the target's Kubernetes/RKE2 skew rules and packaged Cilium/containerd
   changes. Do not skip Kubernetes minor versions or upgrade a worker ahead of
   the server. Verify compatibility with the selected stock Kata handler,
   external virtio-fs/overlayfs integration, CSI components and SELinux policy.
2. Review exact server/agent, common and compatible SELinux RPM releases, signed
   repositories and the proposed package transaction. Existing repository
   exclusions block ordinary RKE2 updates: override only the required reviewed
   exclusions for that exact transaction. Do not disable signature checks or use
   an unpinned install script. Review any target-minor repository change first.
3. Review version-dependent tooling before starting. The backup helper rejects
   versions other than its maintained pin; enrollment and chart render checks
   also contain version assumptions. Prepare their compatible
   updates and checks without assuming they continue to work after an RPM change.
   Preserve the timer's intended schedule and make failed/missed backup runs visible.
4. Complete the common baseline and approved pre-upgrade snapshot/custody checks.
   Inventory server-resident workloads; cordon/drain evictable workloads as
   applicable. The server taint does not mean all system workloads are absent.
5. Upgrade only the existing server's reviewed RPM set. Restart `rke2-server`
   under the approved window. Expect API, scheduling and reconciliation downtime;
   do not replace its VM or reset etcd. Treat a kernel reboot as a separate
   explicitly planned action, not an incidental package-upgrade repair.
6. Before touching a worker, require the target server version, API readiness
   through the stable TLS endpoint, unchanged node/CA/etcd identities, healthy
   single-member etcd, retained taint and converged Cilium/Helm resources. The
   read-only `scripts/check-control-plane.py` supports an explicit
   `--expected-version`, but checks neither etcd membership nor application health.
7. Upgrade one drained worker's exact agent/common/SELinux RPM set, restart
   `rke2-agent`, then complete the worker return-to-service checks above. Verify
   the peer and remaining capacity before proceeding to the second worker.
8. Confirm all intended versions, ordinary/Kata execution on both workers,
   allowed/denied policy paths, service announcements on both VLANs and required
   mounts. Recheck actual backup operation/freshness with compatible tooling.
   Record downtime and remove owned test resources. Uncordon only verified nodes.

Updating bootstrap pins does not upgrade a running guest. Keep future-bootstrap
changes separate from in-place package changes and reject any plan that would
recreate useful node data as an upgrade mechanism.

### Stop and recovery

Stop at the first unhealthy gate; do not upgrade the next node. Keep affected
workers cordoned and remove Kata eligibility if runtime capability is uncertain.
Preserve identities, configuration and protected diagnostics. If supported by the
reviewed release, restore an identified configuration error through its existing
owner; do not delete Helm release state or reinstall the cluster as a repair.

An RPM downgrade or VM snapshot rollback is not a generic safe rollback after
datastore changes. Review the release-specific rollback procedure and data-loss
implications separately. Production `cluster-reset`, datastore restoration and
VM replacement need new explicit authorization. Production restoration remains unqualified.
If etcd quorum/identity is unclear, preserve the
original server and escalate rather than initializing another cluster.

## Outage and host-maintenance runbooks

These are bounded guest-level exercises, not permission to shut down physical
hosts, stop TrueNAS or administer RustFS/OpenBao. Agree the exact simulated
failure and its limitations before the window.

| Event | Expected limitation | Return sequence |
| --- | --- | --- |
| Server-only restart/outage | API, scheduling and reconciliation stop. Existing worker pods may continue; service reachability and L2 lease renewal are not guaranteed. | Recover the same server/datastore; qualify API/etcd before assessing reconciliation and workloads. |
| `compute` loss | Server and compute worker are absent; store pods may continue without scheduling or guaranteed service reachability. | Restore compute connectivity/reservations, then the original server and its API/etcd, then the compute worker; qualify workloads and services. |
| `store` loss | API remains on compute; store worker and TrueNAS-backed data are unavailable. Remaining worker capacity may be insufficient. | Operator restores storage/network prerequisites, then the store worker; verify mounts, runtime and both VLANs. Never delete retained data to make pods Ready. |

### Planned window

1. Complete the common baseline, approve downtime and record the external clients
   for each VLAN. Check approved/denied policy paths before disruption.
2. For compute maintenance, drain its worker while the API is still available.
   Stop the reviewed worker guest and server guest only when those exact actions
   are approved. A server-only restart does not simulate complete compute loss.
3. For store maintenance, drain its worker while the API is healthy. A worker-only
   stop does not simulate loss of TrueNAS. Leave storage administration to its
   operator; report storage-loss behavior as untested unless separately exercised.
4. Observe the agreed outage until its deadline: API availability, existing pod
   behavior and external HTTP/ARP or neighbor observations for each service VLAN.
   Record failures as failures; an allocated service IP is not reachability proof.
5. Restore in the table's order and run the return gates below. Cancel remaining
   disruption if the earlier step fails; do not combine it with an upgrade.

### Unplanned loss

First establish which host/guest/network/storage failed and whether the original
server still exists. Do not create replacement members, delete stale-looking
nodes or reinitialize etcd while ownership is uncertain. If the API is down,
cordon/drain and new scheduling are unavailable; do not claim they succeeded.
Recover the original guests and dependencies before considering a separately
authorized datastore recovery. Do not promise automatic failover or usable NFS
on a surviving worker when store/TrueNAS is absent.

### Return gates and evidence

Require the original server node, CA, etcd cluster/member identities, healthy API
and intended service enablement. For guest restarts, require original worker
UIDs/MACs/reservations; replacement has a separate reviewed identity transition.
Then verify Cilium/Helm convergence, ordinary and fresh explicit Kata execution,
mounts, both worker VLANs and external service announcements/HTTP. Recheck policy
with the API back: inability to reach a pod during outage is not observed denial,
and dynamic policy updates during API downtime are not promised.

Privately record start/return times, identities, last completed step, expected
versus observed behavior and cleanup. Retain a concise sanitized result in the
issue, not raw credentials, journals or resource dumps. A failed check leaves
the operation incomplete; do not relabel a timeout as availability evidence.

## Future one-to-three server expansion

This is a design checklist for a later implementation, not an enrollment command
or a current HA claim. Three VMs on two hosts are not three independent physical
failure domains. Permanent two-member etcd is not fault tolerant.

1. Approve placement, capacity, failure domains and an API/registration frontend
   independent of Kubernetes and Cilium workload L2 announcements. Keep the
   existing stable API DNS name and TLS SAN; support the verified API and registration listeners.
2. Confirm backups and independent matching token custody, acknowledging unproven
   restoration. Define trust, health checks, DNS transition, permitted etcd
   peer/client paths and rollback/stop bounds before changing the live endpoint.
3. Validate the frontend with only the original server as a healthy backend, then
   move the stable endpoint under a reviewed DNS/network change. Keep the previous
   target recorded. Verify administrator and agent access through both ports.
4. Extend the owning infrastructure without replacing/importing away the existing
   server. Provision each new server with unique identity, empty datastore and
   matching critical RKE2 settings. Configure the existing registration endpoint
   and protected server-token file before first start; never start a separate
   cluster and try to merge it later. Keep credentials out of OpenTofu/cloud-init.
5. Join server two, verify actual etcd membership/health and synchronization, then
   join server three and repeat. The temporary two-member stage requires both
   members for quorum; do not schedule maintenance or stop there as an HA design.
   Admit only healthy backends to the frontend. Preserve worker-only service
   announcements, server taints, cluster identity, CIDRs and workload ownership.
6. Replace single-server-only readiness assumptions before acceptance:
   `check-control-plane.py` deliberately requires exactly one server. Verify three
   healthy voting members and the stable endpoint, not just three Ready nodes.
   Qualify any failure-tolerance claim under a separately approved exercise.

Before membership changes, frontend rollback may return DNS to the healthy
original target. After a join, do not simply power off/delete the new VM or remove
members without reviewing quorum and RKE2's supported member-removal procedure.
Never use a cluster reset or downgrade as an implicit expansion rollback. Keep
backups/custody current throughout; no additional HA deployment is authorized here.

[backup]: BACKUP.md
[workers]: WORKERS.md
[worker-maintenance]: WORKERS.md#maintenance-and-replacement
[exposure]: SERVICE-EXPOSURE.md
[policy]: NETWORK-POLICY.md
[nfs]: NFS.md
[secrets]: SECRETS.md
[manual-upgrade]: https://docs.rke2.io/upgrade/manual_upgrade
