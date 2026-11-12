# Retained NFS Storage

This integration uses the existing external TrueNAS server and stock NFS CSI
4.13.6. It does not create datasets/exports, enforce a server quota or apply
Kubernetes resources through OpenTofu. ALE-48 owns real-backend qualification.

## Ownership And Access

The approved backend is a dedicated POSIX dataset with a 500-GiB aggregate ZFS
`quota`, including snapshots and child datasets. A `refquota` is not the same
limit. Per-PVC subdirectories are not separate datasets; a PVC size request or
reported PV capacity does not enforce a per-PVC quota. Snapshot consumption can
therefore reduce space available to every claim. Dataset snapshots on the same
server are not independent backups or application-consistent recovery evidence.

Use a dedicated non-root NAS identity as the dataset owner/group and Maproot
user/group; leave Mapall blank. Restrict owner/group access rather than making
the export world-writable. Mounts use NFSv4.1, `hard` and AUTH_SYS. No NFS password,
admin credential or long-lived application token is passed through OpenTofu.

Worker-only export clients remain the recommended boundary in ADR 005. The
operator explicitly accepted an unrestricted Hosts list for the initial dedicated
share to allow flexible client addresses. This is a deployment-specific risk,
not a new default: any network-reachable AUTH_SYS client can assert a numeric
UID/GID. POSIX modes and Maproot do not authenticate clients. Preserve upstream
network boundaries; this integration does not authorize firewall changes.

CSI controller and node components select only worker nodes. Their upstream
privileged/host-network mounts and kubelet host paths are confined to the dedicated
`nfs-system` namespace, not granted to application pods. The controller needs NFS
access too. Verify the deployed kubelet root matches the chart's `/var/lib/kubelet`
before installing; do not infer it from a distribution label.

The driver retains `mountPermissions: 0` as its global fallback. The StorageClass
explicitly requests `0770` for its volume directory; this may chmod that directory
on provisioning/mount, not recursively rewrite file ownership. UID/GID chown
parameters are omitted. `CSIDriver.fsGroupPolicy: None` prevents kubelet recursive
ownership changes that can conflict with root-squash. Synthetic consumers use
explicit non-root primary UID/GID and do not set `fsGroup`.

This ownership scheme must be verified against the real export. A future
application with another identity needs an explicit reviewed directory/ACL plan;
the shared test identity is not a tenant-isolation or universal application-user
design. Never fix an ownership failure with Maproot=root, Mapall, `0777`, recursive
share-wide chown or weaker SELinux.

## Prepare The Configuration

Set optional `nfs_storage` in ignored tfvars using `terraform.tfvars.example`:

- `server`: plain private hostname or IPv4 address, not a URL or credential.
- `share`: exact dedicated absolute export path, not the server root or a path
  containing parent traversal. For this implementation, use the confirmed NFSv4
  mount path rather than guessing from a dataset label.
- `storage_class_name`: explicitly selected DNS-label name. The class is always
  non-default; workloads name it directly.
- `qualification_identity.uid` / `.gid`: the approved positive numeric identity
  for owned synthetic consumers, supplied privately rather than committed.

`null` renders nothing. Enabled inputs produce sensitive `nfs_manifests` outputs
for the StorageClass and synthetic qualification resources, without changing
first-boot snippets, VMs, networking or existing useful storage. The native CSI
chart is maintained separately in `platform/nfs.yaml`.

Run `make validate` offline. For the real upstream Helm rendering, download the
archive URL from `platform/nfs.yaml` into a protected working directory, then run:

```bash
make nfs-chart-validate NFS_CHART='<downloaded-chart.tgz>' HELM='<helm-executable>'
```

`NFS_CHART` is required; `HELM` defaults to `helm`. The checker requires Python
with PyYAML and a working Helm executable, verifies the reviewed archive checksum
before rendering, and bounds Helm to 60 seconds. It checks actual rendered worker
placement, digest-pinned images, retained deletion, ownership policy and absence
of implicit storage/snapshot resources. It contacts neither a cluster nor a
network service. Exit 0 means the chart contract passed; nonzero means failure,
not runtime compatibility. Version changes require a newly reviewed checksum,
images and render contract.

## Review And Deploy Under Separate Approval

Before deployment, confirm the dataset exists, exact export path, NFSv4 support,
POSIX ownership/mode, Maproot/Mapall choices, effective export-client restriction
or accepted exception, aggregate quota/snapshot accounting and data-backup owner.
The Kubernetes configuration cannot read back or enforce TrueNAS settings.

Use canonical main and its existing production state for an authorized saved
plan. It must show **no infrastructure resource changes**. Inspect sensitive
outputs privately; reject VM/snippet/DNS/NIC changes and preserve control-plane
identity. Apply only that reviewed unchanged plan to update outputs, not to
deploy Kubernetes. Export `tofu output -json nfs_manifests` to a mode-0600 file
under a protected directory and split its map into new files as described in
the [service-exposure runbook][exposure]. JSON output is unredacted.

Under explicit driver-rollout approval, verify no conflicting driver/chart,
StorageClass or `nfs-system` resources exist, then install the reviewed native
`platform/nfs.yaml` through the existing RKE2 Helm controller. Persist the reviewed
platform file and private StorageClass in separately owned runtime manifest files
on the server, not in cloud-init. Never place the synthetic qualification manifest
in the server's auto-reconciliation directory. Retain operator copies for recovery
and use the same owner for upgrades/removal; do not create a second Helm release.
The bootstrap manifest is intentionally not altered. Removing a manifest file
alone is not proof that its live resources were uninstalled.

Require a successful native install job, one Ready worker controller, a Ready
node plugin on each worker and actual `CSINode` registration before creating the
private StorageClass. Check the rendered driver policy and image digests on the
deployed objects. Abort/no-retry guards stop job retrying, not completed host
actions or subsequent CSI RPC retries. Installation failure is not a reason to
delete runtime sockets, relabel broad directories or reset nodes.

StorageClass parameters are effectively immutable. Reject an existing class with
different backend parameters instead of replacing it underneath consumers.
Neither `Retain` nor `onDelete: retain` can retroactively protect an unrelated
Delete-policy PV. Never patch useful PVs without a reviewed ownership decision.

## Real-Backend Qualification

The generated `qualification.yaml` creates a new restricted `nfs-check`
namespace, a labelled explicit-class RWX claim and two ordinary/two isolated
consumers, one of each per worker. Stop if the namespace or witness claim already
exists; do not adopt unrelated data. Every pod writes a unique synthetic witness
using its UID, syncs the mounted filesystem and then signals readiness through
local emptyDir storage. The readiness probe does not repeatedly access NFS during
an outage. Ready later does not mean storage is currently healthy.

Only after test approval:

1. Capture node/control-plane/etcd identities and existing mounts/data first.
   Verify SELinux enforcing, ordinary runc default and actual Rust Kata/Cloud
   Hypervisor/KVM execution, not just a RuntimeClass field.
2. Deploy the claim and consumers. Verify the bound PV's driver/server/share,
   unique namespace/claim/PV subdirectory, Retain policy and actual NFSv4.1 hard
   mount. Confirm ownership/mode and non-root read/write on each worker/runtime.
3. Record witnesses and hashes privately. Recreate consumers and verify old data
   remains readable; authorize and exercise the required worker-maintenance,
   replacement/remount path separately. A synthetic prerequisite or an earlier
   worker replacement before volume creation does not prove this gate.
4. Qualify backend-unavailable and recovery behavior with a reviewed bounded
   outage method that cannot disrupt unrelated TrueNAS clients. Distinguish
   existing I/O from startup/remount. Hard NFS calls can block beyond a CLI timeout;
   timeout is not cancellation, recovery or a reason to force-unmount/reset.
   Do not substitute `soft` mounts to manufacture a bounded success.
5. Stop all consumers normally and verify no mounts/sandboxes remain before
   deleting the owned claim. Confirm its PV becomes Released and the exact data
   remains. Do not equate Retain with automatic reattachment.
6. For owned test data only, save the PV manifest and data handle, then review a
   replacement claim with explicit `volumeName` and matching class/access/capacity.
   Keep `storageClassName` equal to the existing PV's class, not an empty string.
   Preserve Retain, the existing CSI volume handle and server/share attributes.
   After all old consumers are gone, reserve the owned Released PV for the exact
   new claim name/namespace/UID. Use a reviewed atomic claimRef replacement guarded
   by the old claim UID, rather than leaving it Available to unrelated claimants.
   Read back witnesses; do not provision a second dynamic directory and call it
   recovery. Never run two PVs for the same data handle concurrently.

Retained-data recovery and final disposal are distinct operations. After testing,
keep the PV/backing directory explicitly owned and accounted for until disposal
is approved. Deleting the namespace or PV is not backing-data cleanup, and a
Released PV is not unowned data. Any deletion must name the exact disposable test
directory; never remove the export root, a parent dataset or arbitrary Released
volumes. Do not uninstall the driver while useful claims/mounts remain.

## Operational Limits

Loss of store/TrueNAS makes these volumes unavailable. There is no storage HA,
per-PVC quota, database-consistency proof or independent application-data backup
in this integration. CSI snapshot controllers/classes are disabled; etcd snapshots
do not contain NFS file contents. The operator owns TrueNAS quota/snapshots and
separately approved application-consistent backups; ALE-32 owns cluster recovery.

Troubleshoot API/CSI readiness and PV/PVC events first, then driver registration,
actual mount path/options, export reachability, root mapping and UID/GID/mode,
quota/snapshot exhaustion and SELinux denials. Host-network CSI mounts are a
different path from pod egress policy. Preserve default-deny for workloads and add
only their reviewed dependencies; never permit broad egress to hide a mount issue.

[exposure]: SERVICE-EXPOSURE.md
