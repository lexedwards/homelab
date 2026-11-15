# Service and infrastructure inventory

The architecture views use this logical inventory. It draws on repository sources
and operator input; no live discovery was performed. Update it when placement,
ownership, or deployment changes.

## Reading status

- Defined: tracked infrastructure declares the resource. Its deployment and
  health require separate evidence.
- Recorded: existing operating documentation or linked issue evidence reports
  deployment or qualification. Live status has not been rechecked.
- Operator-confirmed: the operator supplied its current role or placement during
  ALE-47. Repository ownership and recovery testing require separate confirmation.
- Unverified: a dependency is referenced, but the relevant facts are unknown.

Ownership identifies who manages a service. Deployment status needs its own
evidence, regardless of the owner. The live status of services labelled Defined
remains unknown; there is no confirmed list of defined-but-not-deployed services.

## Repository-managed services

| Service | Definition and state owner | Placement in definitions | Evidence and limits |
| --- | --- | --- | --- |
| Proxmox QDevice | [proxmox-qdevice](../services/proxmox-qdevice/README.md) | Incus instance on `micro-node` | Defined; cluster enrollment is operator-managed. Current vote/health not rechecked. |
| Image Catalogue | [image-catalogue](../services/image-catalogue/README.md) | Proxmox VM templates on `store` | Defined; templates supply images for provisioning VMs and do not run applications. |
| Technitium DNS | [technitium-dns](../services/technitium-dns/README.md) | Incus instance on `micro-node` | Existing server/adoption recorded; completed imports and current health require their own evidence. Shared zones belong here; service records belong to their service roots. |
| Uptime Kuma | [uptime-kuma](../services/uptime-kuma/README.md) | Docker application in an Incus instance on `micro-node` | Defined; monitors and application settings remain operator-managed. |
| Tailscale Exit Node | [tailscale-exit-node](../services/tailscale-exit-node/README.md) | Incus instance on `micro-node` | Defined; enrollment, route approval, and tailnet policy remain operator-managed. |
| OpenBao | [openbao](../services/openbao/README.md) | Native service in an Incus instance on `micro-node` | Initialized service recorded in its README and ALE-41. Single server; initialization and unseal remain operator-managed. |
| Kubernetes | [infrastructure root](../services/kubernetes/README.md), separate [API runtime root](../services/kubernetes/runtime/README.md) | Control-plane VM on `compute`; optional worker VM on each Proxmox host | Deployment/worker/backup evidence recorded in [lifecycle runbooks](../services/kubernetes/LIFECYCLE.md). Opt-in layer declarations do not establish rollout. Restore remains unproven. |
| Observability Warehouse | [observability-warehouse](../services/observability-warehouse/README.md) | Alloy collector and Grafana VMs on `compute`; Mimir/Loki/Tempo warehouse VM on `store` by default | Defined placement; actual local-input overrides and current health not rechecked. RustFS and NFS are external to this root. |
| Hello World | [hello-world](../services/hello-world/README.md) | Incus instance on `micro-node` | Defined demonstration service; deployment status and continued use unverified. |

Each service owns its deployment state, including resources created through
shared implementation under `modules/`. The Kubernetes API runtime
has separate state so an unavailable API does not prevent VM recovery.

## Operator-managed applications

The following roles and placements were operator-confirmed during ALE-47.
Application packaging, data locations, backups, and recovery qualification remain
unverified unless noted in future service guidance.

| Service | Role | Placement | Logical subnet |
| --- | --- | --- | --- |
| Service Proxy | Nginx reverse proxy; ACME certificates and TLS termination | Unverified | Unverified |
| Home Assistant | Home automation | `compute`; guest type unverified | IoT |
| Media Server | Jellyfin | `store`; guest type unverified | Service |
| Roon | Music service with local device discovery | `store`; guest type unverified | Trusted; needed for discovery of devices such as wireless DACs |
| Remote Workstation | Arch-based Linux with GPU passthrough | `compute`; guest details unverified | Unverified |

Proxy routes to individual applications remain unverified.

## Operator-managed infrastructure

| Infrastructure | Evidence / responsibility | What is still unverified |
| --- | --- | --- |
| `compute` and `store` Proxmox hosts | [Host](../hosts/compute/README.md) [roots](../hosts/store/README.md) configure providers but manage no resources. Service roots manage selected guests. | Host installation, cluster configuration, storage layout, host backup and recovery. |
| `micro-node` | [Host seed](../hosts/micro-node/README.md) prepares Ubuntu and Incus; it is not continuous host management. | Current host health and off-host recovery coverage. |
| TrueNAS / NFS | [NFS runbook](../services/kubernetes/NFS.md) and [storage ADR](adrs/005-kubernetes-nfs-persistence.md) associate persistent storage with the `store` failure domain. Observability also requires an NFS destination. | Guest/host arrangement, whether consumers share a backend, snapshot/replication policy, independent backup and tested recovery. |
| RustFS | [Observability](../services/observability-warehouse/README.md) and [Kubernetes backups](../services/kubernetes/BACKUP.md) consume operator-owned object storage. The [restore lab](../services/kubernetes/restore-lab/README.md) records an OpenBao KMS dependency. | Exact placement, TrueNAS relationship, encryption/recovery dependency details, and independent durability. |
| UniFi | Root README lists a Dream Machine, aggregation switch, PoE switch, and access point. DHCP reservations, routing, and firewall rules are operator-owned. | Exact model variants, logical topology, policy between subnets, management recovery, and upstream internet equipment. |
| APC UPS | Root README records power protection. | Protected equipment, power dependencies, shutdown coordination, and restart order. |
| Recovery custody | [Backup runbook](../services/kubernetes/BACKUP.md) and [custody ADR](adrs/007-kubernetes-recovery-custody.md) require recovery material independent of Kubernetes. | Complete coverage for every service and independently tested retrieval. Never document secret values or sensitive artifact locations. |

The operator has deferred confirmation of unknown inventory details. Live
discovery and changes to these dependencies require separate approval.

## External systems

- Cloudflare and Let's Encrypt: the OpenBao runbook records public DNS-01
  certificate issuance. Proxy certificate-provider details are unverified; do not
  assume it uses the same integration.
- Tailscale: external coordination and operator-owned tailnet policy support
  remote clients. The exit-node root does not manage the control plane.
- Upstream resolvers, time services, package repositories, image and release
  registries: provisioning and renewal depend on approved upstream services.
  Exact configured providers remain private or unverified.
- Internet connectivity: needed for relevant external integrations; provider,
  physical equipment, and recovery arrangements remain unverified.
