# Homelab Infrastructure and Services

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
    - [Lightweight status page](#lightweight-status-page)
    - [Networked Storage](#networked-storage)
    - [Service Proxy](#service-proxy)
    - [Home Assistant](#home-assistant)
    - [Media Server](#media-server)
    - [Roon](#roon)
    - [Remote Workstation](#remote-workstation)
    - [Observability Warehouse](#observability-warehouse)
  - [Network](#network)
  - [Operations](#operations)
  - [Retired Services](#retired-services)
    - [Local LLM Hosting](#local-llm-hosting)
    - [AI Platforms](#ai-platforms)
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

### Hypervisor Cluster and Quorum Device

### Image Catalogue

[Image Catalogue](services/image-catalogue/README.md) downloads curated cloud
images and exposes them as uniform Proxmox VM templates on the storage host.

### Local DNS

### Lightweight status page

### Networked Storage

### Service Proxy

### Home Assistant

### Media Server

### Roon

### Remote Workstation

### Observability Warehouse

## Network

- Unifi Dream Machine
- Unifi USW Aggregation
- Unifi USW Enterprise 24 POE
- Unifi U7-Pro

## Operations

- APC UPS - 2200VA

## Retired Services

### Local LLM Hosting

### AI Platforms

### Virtual Windows Desktop
