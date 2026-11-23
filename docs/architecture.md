# Architecture views

These Mermaid views show relationships between the hosts and services listed in
the [root README](../README.md). Service READMEs own operating details and evidence.
Live health and firewall configuration are outside the scope of these views.

The diagram labels distinguish the available evidence:

- Defined: declared in repository configuration; live deployment is unverified.
- Recorded: operating documentation reports deployment or
  qualification. Current health has not been rechecked.
- Operator-confirmed: the operator supplied the role or placement. Packaging and
  recovery still need their own evidence.
- Unverified: the relevant detail has not been confirmed.

The lab boundary includes operator-managed services as well as repository-managed
ones. C4 containers mean runnable applications or datastores. The deployment view
maps them onto Docker containers, VMs, Incus instances, and physical machines.

## System context

This C4 context view treats the homelab as one system for orientation. Detailed
service boundaries and interactions appear in the container views.

```mermaid
flowchart LR
    operator["Operator / contributor"]
    users["Household / remote users"]
    devices["Home devices / media clients<br/>Includes Zigbee IoT devices"]
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

Solid arrows show service interactions; dotted arrows identify provisioning,
renewal, or backup paths. Enabled Kubernetes integrations and their
current qualification must be checked against service evidence.

```mermaid
flowchart LR
    subgraph lab["Homelab boundary"]
        dns["Technitium DNS<br/>Name resolution / shared zones<br/>Existing server recorded"]
        bao["OpenBao<br/>Secrets API / integrated Raft datastore<br/>Initialized service recorded"]
        kuma["Uptime Kuma<br/>Manual health/readiness monitors<br/>Operator-confirmed; target list unverified"]
        tailscale["Tailscale agent<br/>Remote internet egress<br/>Defined"]
        qnetd["corosync-qnetd<br/>External quorum vote<br/>Defined; enrollment unverified"]
        proxmox["Proxmox cluster management<br/>Operator-managed"]
        k8s["RKE2 API, etcd and workload runtime<br/>Deployment evidence recorded"]
        nfs["TrueNAS mass storage<br/>NFS / SMB shares<br/>Operator-confirmed; layout unverified"]
        rustfs["RustFS object datastore<br/>Operator-managed; placement unverified"]
        ha["Home Assistant<br/>Zigbee home automation<br/>Operator-confirmed"]
        jellyfin["Jellyfin<br/>Media service<br/>Operator-confirmed"]
        roon["Roon<br/>Music service<br/>Operator-confirmed"]
        workstation["Arch Linux workstation<br/>Other integrations unverified"]
        httpapps["Other HTTP-only web services<br/>Full roster unverified"]
        monitored["Monitored services<br/>Health-check / readiness endpoints<br/>Individual targets unverified"]
        proxy["Nginx reverse proxy<br/>ACME / TLS termination<br/>Jellyfin, Home Assistant and other HTTP services"]
        crowdsec["CrowdSec<br/>Additional firewall protection<br/>Installed alongside Nginx"]
    end
    zigbee["Zigbee IoT devices"]
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
    jellyfin -->|"Reads media"| nfs
    roon -->|"Reads music"| nfs
    ha <-->|"Zigbee communication"| zigbee
    proxy -->|"Forwards HTTP"| jellyfin
    proxy -->|"Forwards HTTP"| ha
    proxy -->|"Forwards HTTP"| httpapps
    crowdsec -->|"Additional firewall protection"| proxy
    kuma -->|"Polls health/readiness"| monitored
```

Kubernetes is grouped here for readability; its API server and etcd datastore
are shown separately below. Both views stay at the C4 container level. The
[root README](../README.md#services) describes confirmed integrations and remaining
unknowns; Kuma's target configuration belongs to its
[service settings](../services/uptime-kuma/README.md).

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

Observability relationships follow its definitions; deployment has not been
rechecked. Kubernetes collection had historical delivery qualification, but the
old cluster is retired. A clean rebuild needs fresh collection/ingestion checks.
Grafana's local database and NFS data need their own backups.

## Deployment and network

Nesting shows placement. Kubernetes and observability placements follow their
definitions; confirmed operator-managed placements are labelled separately.
Dashed links show logical subnet membership. Network reachability, routes, and
firewall allowances require separate verification. Services with unknown placement
stay outside host and subnet groups.

```mermaid
flowchart TB
    subgraph lab["Homelab deployment boundary"]
        subgraph micro["micro-node — physical host / Ubuntu / Incus"]
            microapps["Separate Incus instances<br/>Technitium DNS, OpenBao, Uptime Kuma,<br/>Tailscale Exit Node, Proxmox QDevice<br/>Operating evidence in service READMEs"]
            hello["Hello World Incus instance<br/>Defined demo; live status unverified"]
        end
        subgraph compute["compute — physical Proxmox host"]
            cp["RKE2 control-plane VM<br/>API server + etcd<br/>Defined; previous cluster retired"]
            cw["RKE2 worker VM<br/>Worker runtime<br/>Defined; previous cluster retired"]
            collector["Collector VM<br/>Alloy<br/>Defined default placement"]
            grafana["Visualization VM<br/>Grafana<br/>Defined default placement"]
            ha["Home Assistant / Zigbee integration<br/>Operator-confirmed; guest type unverified"]
            workstation["Arch Linux workstation<br/>GPU passthrough<br/>Operator-confirmed"]
        end
        subgraph store["store — physical Proxmox host"]
            storage["TrueNAS VM / NFS / SMB<br/>Kubernetes volumes, Jellyfin media, Roon music<br/>Placement recorded"]
            sw["RKE2 worker VM<br/>Worker runtime<br/>Defined; previous cluster retired"]
            warehouse["Warehouse VM / Docker Compose<br/>Mimir, Loki, Tempo<br/>Defined default placement"]
            images["Image Catalogue<br/>Defined VM templates; not applications"]
            jellyfin["Jellyfin<br/>Operator-confirmed; guest type unverified"]
            roon["Roon<br/>Operator-confirmed; guest type unverified"]
        end
        subgraph unknown["Placement unverified"]
            rustfs["RustFS object storage<br/>Operator-owned; placement unverified"]
            backupnfs["Observability NFS backup destination<br/>Backend unverified"]
            proxy["Nginx Service Proxy + CrowdSec<br/>Colocation operator-confirmed"]
        end
        subgraph network["Logical network boundaries — operator-managed UniFi"]
            firewall["UniFi Dream Machine<br/>Strict operator-managed firewall"]
            iot["IoT subnet"]
            service["Service subnet"]
            trusted["Trusted subnet"]
            management["Management / cluster connectivity<br/>Exact logical topology unverified"]
        end
        zigbee["Zigbee IoT devices<br/>Radio / coordinator details unverified"]
    end
    ha -.->|"Confirmed membership"| iot
    jellyfin -.->|"Confirmed membership"| service
    roon -.->|"Confirmed membership; local discovery"| trusted
    cp -->|"Cluster management"| cw
    cp -->|"Cluster management"| sw
    cw -->|"Enabled NFS consumption"| storage
    sw -->|"Enabled NFS consumption"| storage
    jellyfin -->|"Media shares"| storage
    roon -->|"Music shares"| storage
    warehouse -->|"Object storage"| rustfs
    warehouse -->|"NFS backup destination"| backupnfs
    ha <-->|"Zigbee"| zigbee
    proxy -->|"Proxied HTTP"| ha
    proxy -->|"Proxied HTTP"| jellyfin
```

Management, application, and storage paths require operator-owned network policy.
The worker runbook defines dual-network attachment, but no numeric network IDs or
address ranges belong here. Do not infer the deployment of Cilium exposure pools
or the subnet of other guests from this simplified view.

Zigbee connects Home Assistant to devices separately from its logical IoT subnet
membership. Coordinator hardware and placement still need documenting.

## Maintaining these views

Edit the Mermaid source alongside relevant infrastructure changes; GitHub renders
the diagrams in place. Review the rendered views, links, and privacy before merging.
Keep names, ownership, placement, status, and dependencies consistent with the root
overview and service documentation. Current service health requires live checks.
