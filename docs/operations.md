# Operations and recovery

This cross-service guide helps scope an operation. It does not authorize live
discovery, plans/applies, restarts, recovery exercises, or destructive changes.
Use the service's runbook and obtain approval for the exact operation first.
The [root README](../README.md) lists services; [architecture views](architecture.md)
show their relationships. This guide covers the consequences of those dependencies.

## Distinguish dependency types

- Runtime: needed to serve requests or access useful data. Existing cached
  state can mask a failure; one successful request does not disprove a dependency.
- Provisioning / renewal: needed to create, enroll, update, or renew a service.
  A DNS API used to publish a record is not automatically a runtime API dependency.
- Recovery: needed to retrieve state, credentials, and restore useful service.
  Recovery dependencies can differ from ordinary runtime dependencies.

## Before an operation

Identify the state owner and recovery inputs in the service's runbook. Host seeds
prepare first boot; service data needs separate backups. Reimaging `micro-node`
can erase its instances and volumes. Never initialize existing OpenBao storage
again or re-provision a Kubernetes server over useful etcd data.

Check each affected consumer's data and credential requirements:

- NFS Retain policy protects against automatic volume deletion. Storage loss
  needs separate backups. Restore and verify shares before checking playback or
  restarting dependent workloads.
- Existing mounted secret files may remain readable during OpenBao loss. Check
  fresh retrieval without deleting useful mounts or weakening authorization.
- Verify that observability backups actually reach their destination. Grafana's
  local database needs its own protection.
- Preserve Kuma's application settings and review its manually configured
  targets after a service change.

The [restore lab](../services/kubernetes/restore-lab/README.md#recovery-inputs)
records RustFS's OpenBao KMS dependency. Encrypted snapshot retrieval currently
requires the functioning external KMS. Independent OpenBao/key recovery remains
deferred. Resolve key availability before choosing an order that requires one
service to restore the other. The exact shared storage
layout, encryption recovery arrangements, and application backup coverage remain
unverified.

## Failure impact

| Failure | Expected impact / uncertainty |
| --- | --- |
| `micro-node` loss | Removes its hosted services, including local DNS, OpenBao, monitoring, exit-node access, and the external quorum voter if deployed. Proxmox/data hosts surviving does not preserve these functions. Quorum outcome depends on the remaining votes. |
| `compute` loss | Removes the sole defined control plane, compute worker, default collector/Grafana placement, Home Assistant, and workstation. Workloads surviving on `store` may keep serving requests while scheduling and cluster management are unavailable. |
| `store` loss | Removes its worker, default warehouse placement, Jellyfin, Roon, and the TrueNAS VM. Its NFS-backed workloads and media consumers lose storage access. |
| DNS or upstream network loss | Can block new connections, bootstrap, administration, upstream access, and certificate renewal. IP-only or cached success does not qualify recovery. |
| TrueNAS loss | Disrupts NFS-backed Kubernetes volumes and access to Jellyfin media and Roon music. NFS/SMB clients lose their relevant shares. Exact shared physical failure domains remain unverified. |
| RustFS loss | Affects telemetry object storage and Kubernetes snapshot availability. Its placement and relationship to TrueNAS remain unverified. |
| Service Proxy loss | Interrupts proxied access to Jellyfin, Home Assistant, and other configured HTTP services. CrowdSec's colocated protection is also unavailable; the Dream Machine firewall remains a separate layer. Direct backend access depends on operator-owned network policy. |
| Power loss | UPS coverage, orderly shutdown, and automatic restart remain unverified. |

These expectations come from the documented dependencies. No new host-loss
exercises were performed. Check isolation, routing, and firewall policy separately
from logical subnet membership.

## Recovery planning order

This recovery checklist is untested. Resolve private prerequisites and dependency
cycles before executing any restore.

1. Establish safe power, network administration, time, name-resolution bootstrap,
   independent operator access, and retrieval of protected recovery records.
2. Recover host/platform prerequisites and service storage using the relevant
   host/service procedures. Account for QDevice voting before cluster changes.
3. Restore external shared services such as DNS, secrets, and storage in an order
   validated against their private bootstrap and encryption dependencies. Do not
   assume RustFS can recover without OpenBao, or that OpenBao recovery requires
   RustFS; resolve the actual configuration first.
4. Recover Kubernetes's sole server from an approved matching snapshot/token
   only through its reviewed recovery procedure; then recover workers, runtime
   integration, and retained data. Never initialize a replacement etcd over useful
   data or use re-provisioning as an implicit restore.
5. Restore applications and observability from their own state owners. Verify
   real data access, secret retrieval, TLS identity, client access, and monitoring
   from intended logical networks. Check process startup as part of that validation.

For every proposed operation, record its target, known state owner, protected
backup/recovery inputs, stop conditions, validation, and unrehearsed assumptions.
Keep connection values and raw evidence private.

## Existing runbooks and limits

- [Kubernetes lifecycle](../services/kubernetes/LIFECYCLE.md): recorded worker
  maintenance and off-node backup evidence; upgrades and host-loss procedures are
  unrehearsed. Isolated restoration failed and remains unproven.
- [Kubernetes backups](../services/kubernetes/BACKUP.md), [restore lab](../services/kubernetes/restore-lab/README.md),
  [NFS](../services/kubernetes/NFS.md), and [mounted secrets](../services/kubernetes/SECRETS.md).
- [OpenBao](../services/openbao/README.md): initialized-service protection,
  operator unseal, certificate lifecycle, and recovery custody.
- [Technitium DNS](../services/technitium-dns/README.md): adoption, record ownership,
  export/reconciliation, and recovery limitations.
- [Observability](../services/observability-warehouse/README.md): component state,
  object-store backup boundary, and Grafana database protection.
- [QDevice](../services/proxmox-qdevice/README.md), [Uptime Kuma](../services/uptime-kuma/README.md),
  [Tailscale](../services/tailscale-exit-node/README.md), and [Micro Node](../hosts/micro-node/README.md).

The operator-managed applications still lack service-specific recovery guidance
and evidence of recoverability.
