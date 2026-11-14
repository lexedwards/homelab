# Isolated control-plane restore lab

This separate, service-owned OpenTofu root creates one disposable Rocky Linux 10
amd64 VM. It does not split, import or modify production infrastructure/runtime
state. The lab has no DNS provider, production address reservation, external
storage mounts or workload-secret enrollment. Do not use it as a replacement
production control plane.

## Safety boundary

Provision prerequisites with `fenced = false` only while the VM has no recovery
data. The unique `k8s-restore-` hostname must not match any production node.
The reviewed first-boot installer uses signed, pinned RKE2/SELinux RPMs, disables
the server service and preloads the checksum-pinned core image archive. Its
systemd condition also prevents startup until the restore runner creates the
runtime fence marker. Check cloud-init completion and the prepared marker through
the guest agent after the planned kernel reboot.

Next, apply a fresh, reviewed plan setting `fenced = true`. Proxmox disconnects
the virtual NIC. The restore runner reads Proxmox's `current=1` configuration,
not its pending configuration, and independently verifies the live VM identity,
ownership tags, exact network slot/bridge/VLAN and `link_down=1`, rejecting extra
NICs, passthrough devices and custom QEMU arguments. QEMU guest-agent access uses
the hypervisor channel, not guest networking. The guest also brings its physical
interface down and checks that it has no default routes before receiving data.

**Never reconnect a VM after recovery material has entered it.** Do not change
its first-boot data or run concurrent lab applies during restoration. Keep the
fenced VM for diagnosis if an operation fails; inspect partial state before
retrying. The runner has an exclusive receipt/start marker, not automatic rollback
or a guarantee against another trusted administrator changing the VM.

Restore uses a documentation-only address on loopback, a unique node name,
disabled scheduler and cloud controller, no CNI/kube-proxy, no scheduled snapshots
and no S3 configuration. Existing production-bound pods cannot run under this
new node name. Other restored controllers may reconcile scratch objects, but
cannot reach external services across the disconnected NIC. This is API/etcd
and bootstrap recovery, not workload networking, application-data recovery or HA.

## Inputs and planning

Review host RAM/disk headroom, the catalogue template and guest-ID availability
first. Defaults are four vCPUs, 4 GiB RAM and a 40 GiB disk. Confirm the template
disk fits; never shrink it. All endpoint, host, network, datastore, guest and
administrator values are explicit private inputs; see `terraform.tfvars.example`.
Proxmox chooses the MAC. Use verified HTTPS, `PROXMOX_VE_API_TOKEN` and an SSH agent
for the existing PAM snippet-upload identity. The API identity must support guest
execution (`VM.GuestAgent.Unrestricted` on current Proxmox), not host root SSH.

Run `make init` and `make validate` locally. Persisted operations run from
canonical main only, using this root's own state. For each creation, fence or
cleanup step, generate a new saved plan, inspect its actual changes, then apply
only that unchanged plan. Creation must contain exactly the lab VM and its
bootstrap snippet; fencing must update only the scratch NIC. No production
resource adoption/replacement or provider credential variable is allowed.

Neither cloud-init nor OpenTofu may receive the snapshot, server token or S3
credentials. Sensitive outputs and protected state still contain infrastructure
metadata and need private custody. On-boot startup is deliberately disabled and
VM protection is false because this is an explicitly disposable qualification
guest, unlike production.

## Recovery inputs

Select an actual ready off-node recovery point and preserve its timestamp, native
server-token association and expected compressed-file SHA-256 in protected
metadata. Download that exact object over verified HTTPS using the independently
held dedicated backup credential, outside the cluster. Do not copy the local
production snapshot and call that off-node recovery. Verify its size/hash before
execution. The native runner accepts at most 64 MiB; review larger snapshots
before raising this bound.

Recover the matching server token from independent custody. Do not reread the
live server-token file or rely on Kubernetes/CSI for these inputs. RustFS may
use the functioning external OpenBao KMS under the accepted homelab dependency;
this does not demonstrate recovery while OpenBao is unavailable. Do not request
encryption keys or alter encryption settings.

The protected restore-target JSON contains these non-secret metadata fields:

| Fields | Source |
| --- | --- |
| `proxmox_endpoint`, `node`, `vm_id`, `vm_name`, `bridge`, `vlan_id` | Reviewed lab identity and live fenced configuration |
| `production_vm_ids`, `template_vm_id` | Approved inventory; target must differ |
| `cluster_uid`, `namespace_uids` | Recorded namespace names/UIDs present in the snapshot |
| `cluster_cidr`, `service_cidr` | Owning Kubernetes network definition |
| `scratch_address` | Isolated documentation-only IPv4 address within `192.0.2.0/24` |
| `snapshot_sha256`, `snapshot_timestamp`, `server_token_hash` | Selected recovery-point metadata and corresponding independent token association |
| `server_ca_sha256` | SHA-256 of the original public `server-ca.crt` bytes |

All input files must be operator-owned private regular files, with no symlink at
the file itself. Supply the Proxmox token only through its protected file, never
literal CLI arguments. The runner passes recovery values through API request
bodies/guest stdin, never cloud-init, OpenTofu, guest argv or exported logs.
Disable body/debug logging on this trusted administrative channel. Native reset
output and lab server journal output are suppressed, not published as evidence.

## Execute and verify

Use `../scripts/restore-control-plane.py --help` for required file arguments.
Its default mode reads only the target metadata: no credentials, snapshot,
API calls or guest changes. After procedure review and explicit runtime approval,
add `--execute --receipt <new-private-receipt>` with the same file arguments.
The receipt's parent must already be private and outside Git.

The runner checks snapshot SHA-256 and token association before mutating the
guest; transfers small bounded chunks through the guest agent; writes root-only
recovery files; performs native `rke2 server --cluster-reset` with a local path;
then starts the fenced server. The reset is bounded at ten minutes and subsequent
API observation at fifteen minutes, plus bounded transfer/API operations. A
timeout may leave a running operation: inspect the fenced VM before any retry.

Acceptance requires verified loopback API readiness, expected namespace UIDs,
the original public server CA, exactly one healthy non-learner etcd member and
SELinux enforcing. The lab may have a NotReady scratch node because networking
is intentionally absent; that is not production role/readiness evidence. No
application workload startup or mounted-secret recovery is claimed.

`observed_restore_seconds` measures transfer/reset/API verification on an already
prepared VM with an already downloaded snapshot. Separately record end-to-end
provisioning/download/verification elapsed time and recovery-point age against
the loose four-hour objective. A fingerprint alone is not successful decryption:
the recovered API, CA and datastore checks provide that additional evidence.

After independent receipt review and production health/state-preservation checks,
inspect a fresh destroy plan containing only the scratch VM and its bootstrap
snippet, verify live ownership/fencing once more, and apply that cleanup plan.
All cloned disks, including staged recovery data, are disposable; destruction is
not a cryptographic-erasure guarantee. Preserve protected evidence and independent
recovery copies. No physical host, source template, production VM, remote snapshot,
bucket version or retained NFS data is a cleanup target.
