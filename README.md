# Homelab Infrastructure and Services

Infrastructure definitions and operating guidance for the homelab. Start with the
[documentation guide](docs/README.md), [service inventory](docs/inventory.md), or
[architecture views](docs/architecture.md).

Documentation uses logical service and subnet names. Addresses, port numbers,
private DNS names, network identifiers, credentials, and raw operational evidence
belong in protected operator records, not this repository's documentation.

<!--toc:start-->
- [Homelab Infrastructure and Services](#homelab-infrastructure-and-services)
  - [Hosts](#hosts)
    - [Micro Node](#micro-node)
    - [Compute](#compute)
    - [Storage](#storage)
  - [Services](#services)
    - [Hypervisor Cluster and Quorum Device](#hypervisor-cluster-and-quorum-device)
    - [Image Catalogue](#image-catalogue)
    - [Local DNS](#local-dns)
    - [Lightweight Status Page](#lightweight-status-page)
    - [Tailscale Exit Node](#tailscale-exit-node)
    - [Secrets Management](#secrets-management)
    - [Networked Storage](#networked-storage)
    - [Kubernetes](#kubernetes)
    - [Service Proxy](#service-proxy)
    - [Home Assistant](#home-assistant)
    - [Media Server](#media-server)
    - [Roon](#roon)
    - [Remote Workstation](#remote-workstation)
    - [Observability Warehouse](#observability-warehouse)
  - [Network](#network)
  - [Operations](#operations)
<!--toc:end-->

## Hosts

### Micro Node

Designed to host lightweight services deemed critical enough to be hosted,
clustered, or replicated outside of the main VM platform.

- Raspberry Pi 5 8GB
- WaveShare PoE and M.2 hat

### Compute

Built in Feb '24, originally for experimentation and local LLM Hosting (back
when 8GB VRAM was just enough). Focuses on being primary host for CPU bound tasks.

- 1x AMD Epyc 7302
- 128GB DDR4 ECC
- 2x Micron 74500Pro U.3
- Nvidia GeForce RTX 4060 8GB

### Storage

Second-hand in Jul '25 to replace an off-the-shelf 2-drive NAS gone bad. For
persisted data intensive applications and multi-threaded workloads.

- 2x Intel Xeon Gold 6132
- 128GB DDR4 ECC
- 12x Crucial 2TB SSD
- Intel Arc A380 6GB

## Services

Each service owns its deployment and state. Reusable implementation lives in
repository-level `modules/`, never under another service. Integrations use published
APIs or exported outputs, not private state/code imports. The service skill's
[ownership gate](.agents/skills/create-a-service/SKILL.md#enforce-service-ownership)
and `python3 scripts/check-service-boundaries.py` enforce this separation.

### Hypervisor Cluster and Quorum Device

[Proxmox QDevice](services/proxmox-qdevice/README.md) runs `corosync-qnetd` in
an Incus instance on `micro-node`. It gives the even-sized Proxmox cluster an
external quorum vote outside the cluster itself.

### Image Catalogue

[Image Catalogue](services/image-catalogue/README.md) downloads curated cloud
images and exposes them as uniform Proxmox VM templates on the storage host.

### Local DNS

[Technitium DNS](services/technitium-dns/README.md) runs in an Incus instance on
`micro-node`. It provides local name resolution independently of the Proxmox
cluster.

### Lightweight Status Page

[Uptime Kuma](services/uptime-kuma/README.md) runs in an Incus instance on
`micro-node`. It monitors service availability and hosts the homelab's
lightweight status page outside the Proxmox cluster.

### Tailscale Exit Node

[Tailscale Exit Node](services/tailscale-exit-node/README.md) runs in an Incus
instance on `micro-node`. It lets tailnet clients use the homelab's internet
connection while away from home.

### Secrets Management

[OpenBao](services/openbao/README.md) defines a native, persistent secrets server
in an Incus container on `micro-node`, with systemd swap protection and
service-owned DNS. Initialization and unseal remain operator-managed.

### Networked Storage

TrueNAS-backed NFS provides persistent storage for Kubernetes and a backup
destination for observability. RustFS provides object storage for telemetry and
Kubernetes snapshots. These are operator-managed dependencies; exact placement
and recovery coverage remain [unverified](docs/inventory.md#operator-managed-infrastructure).

### Kubernetes

[Kubernetes](services/kubernetes/README.md) defines an RKE2 control-plane VM on
`compute`, optional workers on `compute` and `store`, Cilium networking, and
opt-in NFS and OpenBao integration. The lifecycle runbooks record operating
evidence and limitations; snapshot restoration remains unproven.

### Service Proxy

Internal Nginx reverse proxy for ACME certificate management and TLS termination.
Placement and configuration ownership are not yet documented.

### Home Assistant

[Home Assistant](https://www.home-assistant.io/installation/) is hosted on
`compute` in the IoT subnet and is operator-managed.

### Media Server

Jellyfin is hosted on `store` in the Service subnet and is operator-managed.

### Roon

[Roon](https://roon.app/en/) is hosted on `store` in the Trusted subnet to support
local device discovery, including wireless DACs. It is operator-managed.

### Remote Workstation

An operator-managed Arch-based Linux workstation is hosted on `compute` with
GPU passthrough.

### Observability Warehouse

[Grafana Alloy, Mimir, Loki, and Tempo](services/observability-warehouse/README.md)
form one observability service with Grafana on three Debian 13 VMs. Alloy runs
in a dedicated collector VM, Mimir, Loki, and Tempo run in a warehouse VM, and
Grafana runs in a separate visualization VM.

## Network

UniFi provides the network platform. The IoT, Service, and Trusted subnets are
logical boundaries, not a claim about their firewall rules. Routing, DHCP,
reservations, and firewall policy remain operator-managed; see the
[deployment/network view](docs/architecture.md#deployment-and-network).

- Unifi Dream Machine
- Unifi USW Aggregation
- Unifi USW Enterprise 24 POE
- Unifi U7-Pro

## Operations

- APC UPS - 2200VA

Architecture choices are recorded in the [architecture decision records](docs/adrs/).
See [operations and recovery](docs/operations.md) for cross-service dependencies
and [contributor guidance](docs/contributing.md) before changing infrastructure.
