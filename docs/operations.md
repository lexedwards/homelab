# Operations and recovery

This cross-service guide helps scope an operation. It does not authorize live
discovery, plans/applies, restarts, recovery exercises, or destructive changes.
Use the service's runbook and obtain approval for the exact operation first.

## Distinguish dependency types

- Runtime: needed to serve requests or access useful data. Existing cached
  state can mask a failure; one successful request does not disprove a dependency.
- Provisioning / renewal: needed to create, enroll, update, or renew a service.
  A DNS API used to publish a record is not automatically a runtime API dependency.
- Recovery: needed to retrieve state, credentials, and restore useful service.
  Recovery dependencies can differ from ordinary runtime dependencies.

| Consumer | Runtime / data dependency | Provisioning, renewal, or recovery boundary |
| --- | --- | --- |
| Proxmox cluster | Healthy nodes, operator-managed cluster network and configured QDevice voting | QDevice instance creation and cluster enrollment have separate owners; confirm quorum before replacement. |
| Incus services | `micro-node`, its local storage, network, and applicable DNS | Host seed prepares first boot; service data needs separate backups. Reimaging the host can erase instances and volumes. |
| OpenBao | Raft data, operator unseal custody, trusted HTTPS and applicable DNS | Cloudflare / Let's Encrypt support certificate renewal. Initializing existing storage again destroys the recovery boundary. |
| Kubernetes | Single control plane and etcd; external API-name resolution; workers for workloads | Image Catalogue / Proxmox for provisioning; independent snapshots, matching server token, API identity, and operator access for recovery. |
| Workloads using NFS | Worker connectivity and TrueNAS-backed data | Retain policy protects against automatic volume deletion. Storage loss requires separate backup protection. |
| Workloads using mounted secrets | OpenBao, enabled provider and auth integration for fresh retrieval | Do not assume cached files prove OpenBao availability or delete useful mounts to test an outage. |
| Observability | Collector → warehouse backends; Grafana → warehouse queries; backends → RustFS | Verify that backups actually reach the NFS destination. Grafana's local database needs separate protection. |
| Operator-managed applications | Confirmed host and logical subnet; other dependencies unverified | Packaging, data ownership, backups, certificate routing, and tested recovery need operator confirmation. |

Do not infer which applications use the proxy, which targets Kuma monitors, or
which producers export telemetry from an intended role alone. RustFS/OpenBao KMS
coupling is mentioned in restore documentation; validate the recovery dependency
before proposing an order that requires one to restore the other.

## Failure impact

| Failure | Expected impact / uncertainty |
| --- | --- |
| `micro-node` loss | Removes its hosted services, including local DNS, OpenBao, monitoring, exit-node access, and the external quorum voter if deployed. Proxmox/data hosts surviving does not preserve these functions. Quorum outcome depends on the remaining votes. |
| `compute` loss | Removes the sole defined control plane, compute worker, default collector/Grafana placement, Home Assistant, and workstation. Workloads surviving on `store` may keep serving requests while scheduling and cluster management are unavailable. |
| `store` loss | Removes its worker, default warehouse placement, Jellyfin and Roon. Existing Kubernetes runbooks associate TrueNAS-backed data loss with this host failure; do not assume storage independence. |
| DNS or upstream network loss | Can block new connections, bootstrap, administration, upstream access, and certificate renewal. IP-only or cached success does not qualify recovery. |
| RustFS / TrueNAS loss | Affects the relevant object/NFS consumers and recovery artifacts. Exact shared physical failure domains remain unverified. |
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
  unrehearsed. Isolated restoration failed and remains unproven; ALE-55 owns the
  follow-up.
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
