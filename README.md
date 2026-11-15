# Homelab Infrastructure and Services

Infrastructure definitions and operating guidance for the homelab. Hosts and
services are listed below. See the [architecture views](docs/architecture.md) for
their relationships and [operations and recovery](docs/operations.md) for failure
impact and recovery planning.

Documentation uses logical service and subnet names. IP and MAC addresses, numeric
ports, private DNS names, network identifiers, credentials, private artifact
locations, and raw operational evidence belong only in protected operator records.
Use placeholders even in synthetic documentation examples.

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

[Host preparation](hosts/micro-node/README.md) covers Ubuntu and Incus setup.

- Raspberry Pi 5 8GB
- WaveShare PoE and M.2 hat

### Compute

Built in Feb '24, originally for experimentation and local LLM Hosting (back
when 8GB VRAM was just enough). Focuses on being primary host for CPU bound tasks.

[Host configuration](hosts/compute/README.md) currently defines the Proxmox
provider only; service roots manage their guests separately.

- 1x AMD Epyc 7302
- 128GB DDR4 ECC
- 2x Micron 74500Pro U.3
- Nvidia GeForce RTX 4060 8GB

### Storage

Second-hand in Jul '25 to replace an off-the-shelf 2-drive NAS gone bad. For
persisted data intensive applications and multi-threaded workloads.

This host is named `store` in the infrastructure definitions.
[Host configuration](hosts/store/README.md) currently defines the Proxmox provider
only; service roots manage their guests separately.

- 2x Intel Xeon Gold 6132
- 128GB DDR4 ECC
- 12x Crucial 2TB SSD
- Intel Arc A380 6GB

## Services

The summaries below describe repository definitions and operator-confirmed
details. Service READMEs hold prerequisites, state ownership, procedures, and
operating evidence. Definitions alone leave live deployment and health unverified.

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
images and exposes them as uniform Proxmox VM templates on `store`.

### Local DNS

[Technitium DNS](services/technitium-dns/README.md) runs in an Incus instance on
`micro-node`. It provides local name resolution independently of the Proxmox
cluster.

### Lightweight Status Page

[Uptime Kuma](services/uptime-kuma/README.md) runs in an Incus instance on
`micro-node`. It monitors service availability and hosts the homelab's
lightweight status page outside the Proxmox cluster. It polls health-check and
readiness endpoints across the homelab. Monitors are configured manually; no
suitable automation is currently in use.

### Tailscale Exit Node

[Tailscale Exit Node](services/tailscale-exit-node/README.md) runs in an Incus
instance on `micro-node`. It lets tailnet clients use the homelab's internet
connection while away from home.

### Secrets Management

[OpenBao](services/openbao/README.md) defines a native, persistent secrets server
in an Incus container on `micro-node`, with systemd swap protection and
service-owned DNS. Initialization and unseal remain operator-managed.

### Networked Storage

TrueNAS is the mass-storage system. It exposes NFS and SMB shares, providing
persistent storage for Kubernetes workloads that use NFS, Jellyfin's media, and
Roon's music. TrueNAS runs as an operator-managed VM on `store`, as recorded in
[NFS qualification](services/kubernetes/NFS.md). Observability also requires an
NFS backup destination. RustFS provides object storage for telemetry and Kubernetes
snapshots; its placement remains unverified. Storage share layouts, independent
backup/recovery coverage, Jellyfin/Roon share protocols, and the backend of
observability's NFS destination still need confirming.

### Kubernetes

[Kubernetes](services/kubernetes/README.md) defines an RKE2 control-plane VM on
`compute`, optional workers on `compute` and `store`, Cilium networking, and
opt-in NFS and OpenBao integration. The lifecycle runbooks record operating
evidence and limitations; snapshot restoration remains unproven.

### Service Proxy

Internal Nginx reverse proxy for ACME certificate management and TLS termination.
It fronts Jellyfin, Home Assistant, and other HTTP-only services such as web apps.
CrowdSec is installed alongside Nginx for additional firewall protection,
supplementing the strict firewall on the UniFi Dream Machine. Proxy placement and
the CrowdSec enforcement configuration still need documenting.

### Home Assistant

[Home Assistant](https://www.home-assistant.io/installation/) is hosted on
`compute` in the IoT subnet and connects to IoT devices over Zigbee. It is
operator-managed.

### Media Server

Jellyfin is hosted on `store` in the Service subnet, with its media on TrueNAS.
It is operator-managed.

### Roon

[Roon](https://roon.app/en/) is hosted on `store` in the Trusted subnet to support
local device discovery, including wireless DACs. Its music is stored on TrueNAS.
It is operator-managed.

### Remote Workstation

An operator-managed Arch-based Linux workstation is hosted on `compute` with
GPU passthrough.

### Observability Warehouse

[Grafana Alloy, Mimir, Loki, and Tempo](services/observability-warehouse/README.md)
form one observability service with Grafana on three Debian 13 VMs. Alloy runs
in a dedicated collector VM, Mimir, Loki, and Tempo run in a warehouse VM, and
Grafana runs in a separate visualization VM. The definitions place the collector
and Grafana on `compute`, and the warehouse on `store`, by default; current
deployment inputs and health have not been rechecked.

The [Hello World](services/hello-world/README.md) root is an Incus provisioning
example on `micro-node`; its current deployment is unverified.

## Network

UniFi provides the network platform, including the logical IoT, Service, and
Trusted subnets. The operator manages routing, DHCP, reservations, and firewall
policy. See the [deployment/network view](docs/architecture.md#deployment-and-network).

- Unifi Dream Machine
- Unifi USW Aggregation
- Unifi USW Enterprise 24 POE
- Unifi U7-Pro

## Operations

- APC UPS - 2200VA

UPS coverage and shutdown/restart coordination remain unverified.

[Operations and recovery](docs/operations.md) covers failures that span services
and links to the relevant runbooks. Host READMEs cover host preparation; service
READMEs own service procedures; module READMEs describe shared implementation
contracts. [Architecture decision records](docs/adrs/) preserve design rationale.
Deployment evidence and review records stay in the linked issues and PRs.
For offline documentation checks and local diagram rendering, see
[maintaining the architecture views](docs/architecture.md#maintaining-these-views).
