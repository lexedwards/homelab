provider "proxmox" {
  endpoint = var.proxmox_endpoint
  insecure = false
  ssh {
    agent    = true
    username = var.proxmox_ssh_username
    node {
      name    = var.host.node
      address = var.host.ssh_address
    }
  }
}

locals {
  user_data = templatefile("${path.module}/user-data.tftpl", {
    name           = var.lab.name
    cloud_user     = var.lab.cloud_user
    ssh_keys       = sort(tolist(var.lab.ssh_keys))
    installer      = base64encode(file("${path.module}/../cloud-init/install-server.sh"))
    node_preflight = base64encode(file("${path.module}/../config/node-preflight.sh"))
    prepare_script = base64encode(file("${path.module}/prepare.sh"))
  })
}

resource "proxmox_virtual_environment_file" "bootstrap" {
  node_name    = var.host.node
  datastore_id = var.host.snippet_datastore_id
  content_type = "snippets"
  source_raw {
    file_name = "${var.lab.name}-cloud-config.yaml"
    data      = local.user_data
  }
}

resource "proxmox_virtual_environment_vm" "scratch" {
  name        = var.lab.name
  description = "Disposable isolated Kubernetes restore qualification; never reconnect after staging recovery data."
  node_name   = var.host.node
  vm_id       = var.lab.vm_id
  tags        = ["iac", "kubernetes-restore-lab"]
  started     = true
  on_boot     = false
  protection  = false
  migrate     = false
  bios        = "ovmf"
  machine     = "q35"
  boot_order  = ["scsi0"]
  clone {
    vm_id        = var.template.vm_id
    node_name    = var.template.node
    datastore_id = var.host.vm_datastore_id
    full         = true
    retries      = 3
  }
  agent {
    enabled = true
    trim    = true
    wait_for_ip {
      disabled = true
    }
  }
  cpu {
    type  = "host"
    cores = 4
  }
  memory {
    dedicated = 4096
  }
  scsi_hardware = "virtio-scsi-single"
  disk {
    datastore_id = var.host.vm_datastore_id
    interface    = "scsi0"
    size         = 40
    discard      = "on"
    iothread     = true
  }
  efi_disk {
    datastore_id      = var.host.vm_datastore_id
    type              = "4m"
    pre_enrolled_keys = true
  }
  initialization {
    datastore_id      = var.host.vm_datastore_id
    user_data_file_id = proxmox_virtual_environment_file.bootstrap.id
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }
  network_device {
    bridge       = var.host.bridge
    vlan_id      = var.host.vlan_id
    model        = "virtio"
    disconnected = var.fenced
  }
  serial_device {}
  operating_system {
    type = "l26"
  }
  lifecycle {
    precondition {
      condition     = !contains(var.production_vm_ids, var.lab.vm_id) && var.lab.vm_id != var.template.vm_id
      error_message = "Scratch and production/template guest IDs must differ."
    }
  }
}

output "scratch_identity" {
  value = {
    node   = var.host.node
    vm_id  = var.lab.vm_id
    name   = var.lab.name
    fenced = var.fenced
  }
  sensitive = true
}
