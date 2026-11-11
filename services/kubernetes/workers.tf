locals {
  worker_hosts = nonsensitive(toset(keys(var.workers)))
  worker_rke2_config = {
    for host, worker in var.workers : host => jsonencode({
      "node-name"  = worker.name
      "server"     = "https://${var.api_dns.name}:9345"
      "token-file" = "/etc/rancher/rke2/join-token"
      "selinux"    = true
      "node-label" = ["homelab.io/role=worker", "topology.kubernetes.io/zone=${host}"]
    })
  }
  worker_cloud_init = {
    for host, worker in var.workers : host => templatefile("${path.module}/cloud-init/worker-user-data.tftpl", {
      hostname           = worker.name
      cloud_user         = var.cloud_user
      public_keys        = sort(tolist(var.cloud_ssh_public_keys))
      rke2_version       = var.rke2_version
      selinux_version    = var.rke2_selinux_version
      rke2_config_base64 = base64encode(local.worker_rke2_config[host])
      installer_base64   = base64encode(file("${path.module}/cloud-init/install-agent.sh"))
      preflight_base64   = base64encode(file("${path.module}/config/node-preflight.sh"))
      service_network    = file("${path.module}/config/worker-service.nmconnection")
    })
  }
}

resource "proxmox_virtual_environment_file" "worker" {
  for_each     = local.worker_hosts
  node_name    = each.key
  datastore_id = var.proxmox_nodes[each.key].snippet_datastore_id
  content_type = "snippets"
  source_raw {
    data      = local.worker_cloud_init[each.key]
    file_name = "kubernetes-worker-cloud-config.yaml"
  }
}

resource "proxmox_virtual_environment_file" "worker_network" {
  for_each     = local.worker_hosts
  node_name    = each.key
  datastore_id = var.proxmox_nodes[each.key].snippet_datastore_id
  content_type = "snippets"
  source_raw {
    data      = file("${path.module}/cloud-init/worker-network-data.yaml")
    file_name = "kubernetes-worker-network-config.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "worker" {
  for_each    = local.worker_hosts
  name        = var.workers[each.key].name
  description = "Dedicated RKE2 agent; enrollment and runtime qualification are separate operations."
  node_name   = each.key
  vm_id       = var.workers[each.key].vm_id
  tags        = ["iac", "kubernetes", "worker"]
  started     = true
  on_boot     = true
  protection  = true
  migrate     = false
  bios        = "ovmf"
  machine     = "q35"
  boot_order  = ["scsi0"]

  clone {
    vm_id        = var.template.vm_id
    node_name    = var.template.node_name
    datastore_id = var.proxmox_nodes[each.key].vm_datastore_id
    full         = true
    retries      = 3
  }
  agent {
    enabled = true
    trim    = true
    wait_for_ip { ipv4 = true }
  }
  cpu {
    type  = "host"
    cores = var.worker_resources.cpu_cores
  }
  memory { dedicated = var.worker_resources.memory_mb }
  scsi_hardware = "virtio-scsi-single"
  disk {
    datastore_id = var.proxmox_nodes[each.key].vm_datastore_id
    interface    = "scsi0"
    size         = var.worker_resources.disk_size_gb
    discard      = "on"
    iothread     = true
    ssd          = true
  }
  efi_disk {
    datastore_id      = var.proxmox_nodes[each.key].vm_datastore_id
    type              = "4m"
    pre_enrolled_keys = true
  }
  initialization {
    datastore_id         = var.proxmox_nodes[each.key].vm_datastore_id
    user_data_file_id    = proxmox_virtual_environment_file.worker[each.key].id
    network_data_file_id = proxmox_virtual_environment_file.worker_network[each.key].id
  }
  network_device {
    bridge  = var.proxmox_nodes[each.key].vm_bridge
    vlan_id = var.primary_vlan_id
    model   = "virtio"
  }
  network_device {
    bridge  = var.workers[each.key].service_bridge
    vlan_id = var.service_vlan_id
    model   = "virtio"
  }
  operating_system { type = "l26" }
  serial_device { device = "socket" }
  vga { type = "serial0" }
}

output "worker_dhcp_leases" {
  description = "Guest-agent addresses matched to Proxmox-owned primary/secondary MACs; reserve both upstream. Not proof of guest or cluster readiness."
  sensitive   = true
  value = {
    for host, vm in proxmox_virtual_environment_vm.worker : host => [
      for nic in vm.network_device : {
        mac_address = nic.mac_address
        ipv4_addresses = try(vm.ipv4_addresses[index(
          [for mac in vm.mac_addresses : lower(mac)], lower(nic.mac_address)
        )], [])
      }
    ]
  }
}
