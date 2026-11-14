# Architecture views

These reviewed Mermaid views describe logical relationships, not live health or
firewall configuration. The [inventory](inventory.md) owns names, placement, and
evidence status. **Defined**, **recorded**, **operator-confirmed**, and
**unverified** have the meanings given there. No view proves deployment.

The lab boundary includes operator-managed services as well as repository-managed
ones. C4 containers below mean runnable applications or datastores, not Docker
containers, VMs, Incus instances, or physical machines. The deployment view maps
those applications onto infrastructure separately.

## System context

This C4 context view treats the homelab as one system for orientation. Detailed
service boundaries and interactions appear in the container views.

```mermaid
flowchart LR
    operator["Operator / contributor"]
    users["Household / remote users"]
    devices["Home devices / media clients"]
    lab["Homelab system<br/>Automation, media, remote access and shared infrastructure"]
    certificates["Cloudflare / Let's Encrypt<br/>External certificate dependencies"]
    tailnet["Tailscale<br/>External coordination"]
    upstream["Upstream DNS, time, packages and images<br/>External dependencies"]
    operator -->|"Administers and recovers"| lab
    users -->|"Uses applications and remote access"| lab
    devices <-->|"Automation and media interactions"| lab
    lab -->|"OpenBao certificate issuance / renewal"| certificates
    lab -->|"Exit-node coordination"| tailnet
    lab -->|"Resolution, synchronization and provisioning"| upstream
```

## Container views

### Shared infrastructure and consumers

Arrows name interactions rather than implying that every service needs every
other service. Solid arrows show service interactions; dotted arrows identify
provisioning, renewal, or backup paths. Enabled Kubernetes integrations and their
current qualification must be checked against service evidence.

```mermaid
flowchart LR
    subgraph lab["Homelab boundary"]
        dns["Technitium DNS<br/>Name resolution / shared zones<br/>Existing server recorded"]
        bao["OpenBao<br/>Secrets API / integrated Raft datastore<br/>Initialized service recorded"]
        kuma["Uptime Kuma<br/>Availability monitoring / local app data<br/>Defined; monitor inventory unverified"]
        tailscale["Tailscale agent<br/>Remote internet egress<br/>Defined"]
        qnetd["corosync-qnetd<br/>External quorum vote<br/>Defined; enrollment unverified"]
        proxmox["Proxmox cluster management<br/>Operator-managed"]
        k8s["RKE2 API, etcd and workload runtime<br/>Deployment evidence recorded"]
        nfs["TrueNAS NFS service<br/>Operator-managed; layout unverified"]
        rustfs["RustFS object datastore<br/>Operator-managed; placement unverified"]
        apps["Home Assistant / Jellyfin / Roon / workstation<br/>Operator-confirmed; integrations unverified"]
        proxy["Nginx reverse proxy<br/>ACME / TLS termination<br/>Operator-confirmed; routes unverified"]
    end
    upstream["Upstream resolvers"]
    certs["Cloudflare / Let's Encrypt"]
    coordination["Tailscale coordination"]
    dns -->|"Configured forwarding"| upstream
    bao -->|"Resolves names"| dns
    bao -.->|"Certificate issuance / renewal"| certs
    proxmox -->|"Configured quorum client relationship"| qnetd
    tailscale -->|"Coordinates remote access"| coordination
    k8s -->|"Host-side API name resolution"| dns
    k8s -->|"Enabled workload-secret delivery"| bao
    k8s -->|"Enabled persistent-volume access"| nfs
    k8s -.->|"Off-node etcd snapshot upload"| rustfs
```

The application, proxy, and monitoring nodes are deliberately not connected to
invented backends or monitors. Kubernetes is grouped here for readability; its
API server and etcd datastore are shown separately below. This is not a C4
component-level model.

### Kubernetes and observability applications

```mermaid
flowchart LR
    subgraph lab["Homelab boundary"]
        api["RKE2 Kubernetes API server<br/>Cluster management"]
        etcd[("etcd<br/>Cluster state")]
        workloads["Worker application containers<br/>Ordinary / opt-in isolated runtime"]
        secrets["OpenBao CSI provider<br/>Enabled mounted-secret delivery"]
        bao["OpenBao<br/>External to Kubernetes"]
        nfs[("TrueNAS NFS<br/>Retained workload data")]
        collector["Grafana Alloy<br/>Telemetry collection"]
        mimir["Mimir<br/>Metrics storage / query"]
        loki["Loki<br/>Log storage / query"]
        tempo["Tempo<br/>Trace storage / query"]
        grafana["Grafana<br/>Visualization / local application database"]
        rustfs[("RustFS<br/>Telemetry blocks / snapshot buckets")]
    end
    producers["Approved telemetry producers<br/>Actual producer inventory unverified"]
    viewers["Grafana users"]
    api -->|"Reads / writes cluster state"| etcd
    workloads -->|"Cluster API access where authorized"| api
    workloads -->|"Enabled persistent-volume access"| nfs
    workloads -->|"Enabled file-mounted secrets"| secrets
    secrets -->|"Scoped secret retrieval"| bao
    producers -->|"Sends telemetry"| collector
    collector -->|"Writes metrics"| mimir
    collector -->|"Writes logs"| loki
    collector -->|"Writes traces"| tempo
    viewers -->|"Views dashboards"| grafana
    grafana -->|"Queries metrics"| mimir
    grafana -->|"Queries logs"| loki
    grafana -->|"Queries traces"| tempo
    mimir -->|"Stores durable blocks"| rustfs
    loki -->|"Stores durable blocks"| rustfs
    tempo -->|"Stores durable blocks"| rustfs
```

Observability relationships reflect its definitions, not a newly verified
deployment. Kubernetes telemetry export to Alloy is not assumed. RustFS is not a
backup for Grafana's local database or a substitute for NFS data backups.

## Deployment and network

Nesting represents placement, not network reachability. Kubernetes and
observability placements below follow definitions; confirmed operator-managed
placements are labelled separately. Dashed links associate applications with
logical subnets, not routes or firewall allowances. Unknowns stay outside host
and subnet groups rather than acquiring guessed placement.

```mermaid
flowchart TB
    subgraph lab["Homelab deployment boundary"]
        subgraph micro["micro-node — physical host / Ubuntu / Incus"]
            microapps["Separate Incus instances<br/>Technitium DNS, OpenBao, Uptime Kuma,<br/>Tailscale Exit Node, Proxmox QDevice<br/>See inventory for evidence status"]
            hello["Hello World Incus instance<br/>Defined demo; live status unverified"]
        end
        subgraph compute["compute — physical Proxmox host"]
            cp["RKE2 control-plane VM<br/>API server + etcd<br/>Defined; deployment evidence recorded"]
            cw["RKE2 worker VM<br/>Worker runtime<br/>Defined; worker evidence recorded"]
            collector["Collector VM<br/>Alloy<br/>Defined default placement"]
            grafana["Visualization VM<br/>Grafana<br/>Defined default placement"]
            ha["Home Assistant<br/>Operator-confirmed; guest type unverified"]
            workstation["Arch Linux workstation<br/>GPU passthrough<br/>Operator-confirmed"]
        end
        subgraph store["store — physical Proxmox host"]
            sw["RKE2 worker VM<br/>Worker runtime<br/>Defined; worker evidence recorded"]
            warehouse["Warehouse VM / Docker Compose<br/>Mimir, Loki, Tempo<br/>Defined default placement"]
            images["Image Catalogue<br/>Defined VM templates; not applications"]
            jellyfin["Jellyfin<br/>Operator-confirmed; guest type unverified"]
            roon["Roon<br/>Operator-confirmed; guest type unverified"]
        end
        subgraph unknown["Placement unverified"]
            storage["TrueNAS / NFS / RustFS<br/>Operator-owned storage dependencies<br/>NFS tied to store failure domain in runbooks"]
            proxy["Nginx Service Proxy<br/>Operator-confirmed"]
        end
        subgraph network["Logical network boundaries — operator-managed UniFi"]
            iot["IoT subnet"]
            service["Service subnet"]
            trusted["Trusted subnet"]
            management["Management / cluster connectivity<br/>Exact logical topology unverified"]
        end
    end
    ha -.->|"Confirmed membership"| iot
    jellyfin -.->|"Confirmed membership"| service
    roon -.->|"Confirmed membership; local discovery"| trusted
    cp -->|"Cluster management"| cw
    cp -->|"Cluster management"| sw
    cw -->|"Enabled NFS consumption"| storage
    sw -->|"Enabled NFS consumption"| storage
    warehouse -->|"Object storage / NFS destination"| storage
```

Management, application, and storage paths require operator-owned network policy.
The worker runbook defines dual-network attachment, but no numeric network IDs or
address ranges belong here. Do not infer the deployment of Cilium exposure pools
or the subnet of other guests from this simplified view.

## Maintaining these views

Edit Mermaid fences in this file; GitHub renders them in place. No public diagram
renderer or hosted documentation service is required. For a local syntax/render
check, use the pinned Mermaid CLI command in [contributor guidance](contributing.md#documentation-checks).
Generated output is temporary and is not a second source of truth.

The change author updates the inventory and affected views alongside relevant
infrastructure changes. The reviewer checks names, ownership, placement, status,
and dependency meaning across views. Successful rendering is not semantic drift
detection or evidence that a service is running.
