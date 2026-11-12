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
  cilium_bootstrap_values = {
    kubeProxyReplacement = true
    k8sServiceHost       = var.api_dns.name
    k8sServicePort       = 6443
    socketLB             = { enabled = true, hostNamespaceOnly = true }
    routingMode          = "tunnel"
    tunnelProtocol       = "vxlan"
    ipam                 = { mode = "kubernetes" }
    operator             = { replicas = 1 }
  }
  cilium_chart_config = {
    apiVersion = "helm.cattle.io/v1"
    kind       = "HelmChartConfig"
    metadata   = { name = "rke2-cilium", namespace = "kube-system" }
    spec = {
      valuesContent = yamlencode(local.cilium_bootstrap_values)
    }
  }
  cilium_bootstrap_config = yamlencode(local.cilium_chart_config)
  cilium_config = yamlencode(merge(local.cilium_chart_config, {
    spec = { valuesContent = yamlencode(merge(local.cilium_bootstrap_values, local.service_exposure_values)) }
  }))
  cloud_init = templatefile("${path.module}/cloud-init/user-data.tftpl", {
    hostname             = var.control_plane.name
    cloud_user           = var.cloud_user
    public_keys          = sort(tolist(var.cloud_ssh_public_keys))
    rke2_version         = var.rke2_version
    selinux_version      = var.rke2_selinux_version
    rke2_config_base64   = base64encode(local.rke2_config)
    cilium_config_base64 = base64encode(local.cilium_bootstrap_config)
    installer_base64     = base64encode(file("${path.module}/cloud-init/install-server.sh"))
    preflight_base64     = base64encode(file("${path.module}/config/node-preflight.sh"))
  })
  primary_interface_index = try(index(
    [for mac in proxmox_virtual_environment_vm.control_plane.mac_addresses : lower(mac)],
    lower(proxmox_virtual_environment_vm.control_plane.network_device[0].mac_address),
  ), null)
  primary_ipv4 = local.primary_interface_index == null ? null : one([
    for address in proxmox_virtual_environment_vm.control_plane.ipv4_addresses[local.primary_interface_index] : address
    if !startswith(address, "127.") && !startswith(address, "169.254.")
  ])
}

resource "technitium_record" "api" {
  zone      = var.api_dns.zone
  name      = var.api_dns.name
  type      = "A"
  value     = local.primary_ipv4
  ttl       = var.api_dns.ttl
  overwrite = false
  lifecycle {
    precondition {
      condition     = local.primary_ipv4 != null
      error_message = "The primary NIC must report exactly one usable IPv4 lease."
    }
    precondition {
      condition     = local.primary_ipv4 == null ? true : !cidrcontains(var.cluster_networks.pods, local.primary_ipv4) && !cidrcontains(var.cluster_networks.services, local.primary_ipv4)
      error_message = "The observed primary address must not overlap internal cluster networks."
    }
  }
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

resource "proxmox_virtual_environment_file" "control_plane_network" {
  node_name    = "compute"
  datastore_id = local.compute.snippet_datastore_id
  content_type = "snippets"
  source_raw {
    data      = file("${path.module}/cloud-init/network-data.yaml")
    file_name = "kubernetes-control-plane-network-config.yaml"
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
    datastore_id         = local.compute.vm_datastore_id
    user_data_file_id    = proxmox_virtual_environment_file.control_plane.id
    network_data_file_id = proxmox_virtual_environment_file.control_plane_network.id
  }
  network_device {
    bridge  = local.compute.vm_bridge
    vlan_id = var.primary_vlan_id
    model   = "virtio"
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
      condition     = !cidrcontains(var.cluster_networks.pods, cidrhost(var.cluster_networks.services, 0)) && !cidrcontains(var.cluster_networks.services, cidrhost(var.cluster_networks.pods, 0))
      error_message = "Internal pod/Service networks must not overlap each other."
    }
  }
}

output "control_plane_dhcp_lease" {
  description = "Observed primary IP/MAC pair to reserve after deployment; not proof of API readiness or a reservation."
  value = {
    ipv4_address = local.primary_ipv4
    mac_address  = proxmox_virtual_environment_vm.control_plane.network_device[0].mac_address
  }
  sensitive = true
}

output "control_plane_ipv4_addresses" {
  description = "Guest-agent observed addresses, not an API readiness or DHCP-reservation assertion."
  value       = proxmox_virtual_environment_vm.control_plane.ipv4_addresses
  sensitive   = true
}
