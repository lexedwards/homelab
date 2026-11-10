provider "proxmox" {
  endpoint = var.proxmox_endpoint
  insecure = var.proxmox_insecure

  ssh {
    agent    = true
    username = var.proxmox_ssh_username

    dynamic "node" {
      for_each = nonsensitive(toset(keys(var.proxmox_nodes)))
      content {
        name    = node.value
        address = var.proxmox_nodes[node.value].ssh_address
      }
    }
  }
}

provider "technitium" {
  server_url      = var.technitium_server_url
  skip_tls_verify = false
}

locals {
  compute = var.proxmox_nodes["compute"]
  rke2_config = yamlencode({
    "node-name"             = var.control_plane.name
    "node-ip"               = var.control_plane.ipv4_address
    "tls-san"               = [var.api_dns.name]
    "selinux"               = true
    "write-kubeconfig-mode" = "0600"
    "cni"                   = "cilium"
    "disable-kube-proxy"    = true
    "node-taint"            = ["node-role.kubernetes.io/control-plane:NoSchedule"]
    "cluster-cidr"          = var.cluster_networks.pods
    "service-cidr"          = var.cluster_networks.services
    "disable"               = ["rke2-ingress-nginx", "rke2-traefik"]
  })
  cilium_config = yamlencode({
    apiVersion = "helm.cattle.io/v1"
    kind       = "HelmChartConfig"
    metadata   = { name = "rke2-cilium", namespace = "kube-system" }
    spec = {
      valuesContent = yamlencode({
        kubeProxyReplacement = true
        k8sServiceHost       = var.control_plane.ipv4_address
        k8sServicePort       = 6443
        socketLB             = { enabled = true, hostNamespaceOnly = true }
        routingMode          = "tunnel"
        tunnelProtocol       = "vxlan"
        ipam                 = { mode = "kubernetes" }
        operator             = { replicas = 1 }
      })
    }
  })
  cloud_init = templatefile("${path.module}/cloud-init/user-data.tftpl", {
    hostname             = var.control_plane.name
    cloud_user           = var.cloud_user
    public_keys          = sort(tolist(var.cloud_ssh_public_keys))
    rke2_version         = var.rke2_version
    selinux_version      = var.rke2_selinux_version
    rke2_config_base64   = base64encode(local.rke2_config)
    cilium_config_base64 = base64encode(local.cilium_config)
    installer_base64     = base64encode(file("${path.module}/cloud-init/install-server.sh"))
    preflight_base64     = base64encode(file("${path.module}/config/node-preflight.sh"))
    node_ipv4            = var.control_plane.ipv4_address
  })
}

resource "technitium_record" "api" {
  zone      = var.api_dns.zone
  name      = var.api_dns.name
  type      = "A"
  value     = var.control_plane.ipv4_address
  ttl       = var.api_dns.ttl
  overwrite = false
}

resource "proxmox_virtual_environment_file" "control_plane" {
  node_name    = "compute"
  datastore_id = local.compute.snippet_datastore_id
  content_type = "snippets"
  source_raw {
    data      = local.cloud_init
    file_name = "kubernetes-control-plane-cloud-config.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "control_plane" {
  name        = var.control_plane.name
  description = "Initial RKE2 server and single-member etcd; managed by OpenTofu."
  node_name   = "compute"
  vm_id       = var.control_plane.vm_id
  tags        = ["iac", "kubernetes", "control-plane"]
  started     = true
  on_boot     = true
  protection  = true
  bios        = "ovmf"
  machine     = "q35"
  boot_order  = ["scsi0"]
  migrate     = false

  clone {
    vm_id        = var.template.vm_id
    node_name    = var.template.node_name
    datastore_id = local.compute.vm_datastore_id
    full         = true
    retries      = 3
  }
  agent {
    enabled = true
    trim    = true
    wait_for_ip {
      ipv4 = true
    }
  }
  cpu {
    type  = "host"
    cores = var.control_plane_resources.cpu_cores
  }
  memory {
    dedicated = var.control_plane_resources.memory_mb
  }
  scsi_hardware = "virtio-scsi-single"
  disk {
    datastore_id = local.compute.vm_datastore_id
    interface    = "scsi0"
    size         = var.control_plane_resources.disk_size_gb
    discard      = "on"
    iothread     = true
    ssd          = true
  }
  efi_disk {
    datastore_id      = local.compute.vm_datastore_id
    type              = "4m"
    pre_enrolled_keys = true
  }
  initialization {
    datastore_id      = local.compute.vm_datastore_id
    user_data_file_id = proxmox_virtual_environment_file.control_plane.id
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }
  network_device {
    bridge      = local.compute.vm_bridge
    vlan_id     = var.primary_vlan_id
    model       = "virtio"
    mac_address = var.control_plane.mac_address
  }
  operating_system {
    type = "l26"
  }
  serial_device {
    device = "socket"
  }
  vga {
    type = "serial0"
  }
  lifecycle {
    precondition {
      condition     = var.control_plane.vm_id != var.template.vm_id
      error_message = "The server VM ID must differ from the source template ID."
    }
    precondition {
      condition     = contains(keys(var.proxmox_nodes), "compute")
      error_message = "proxmox_nodes must include compute."
    }
    precondition {
      condition     = !cidrcontains(var.cluster_networks.pods, cidrhost(var.cluster_networks.services, 0)) && !cidrcontains(var.cluster_networks.services, cidrhost(var.cluster_networks.pods, 0)) && !cidrcontains(var.cluster_networks.pods, var.control_plane.ipv4_address) && !cidrcontains(var.cluster_networks.services, var.control_plane.ipv4_address)
      error_message = "Internal pod/Service networks must not overlap each other or contain the primary node address."
    }
  }
  depends_on = [technitium_record.api]
}

output "control_plane_ipv4_addresses" {
  description = "Guest-agent observed addresses, not an API readiness or DHCP-reservation assertion."
  value       = proxmox_virtual_environment_vm.control_plane.ipv4_addresses
  sensitive   = true
}
