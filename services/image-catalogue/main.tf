provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  ssh {
    agent       = true
    username    = var.proxmox_ssh_username
    private_key = file(pathexpand(var.proxmox_ssh_private_key_file))
  }
}

resource "proxmox_download_file" "cloud_image" {
  for_each = local.cloud_images

  node_name           = var.node_name
  datastore_id        = var.import_datastore_id
  content_type        = "import"
  url                 = each.value.url
  file_name           = each.value.file_name
  checksum_algorithm  = "sha256"
  checksum            = lower(each.value.sha256_checksum)
  overwrite           = true
  overwrite_unmanaged = true
}

resource "proxmox_virtual_environment_vm" "cloud_template" {
  for_each = local.cloud_images

  lifecycle {
    replace_triggered_by = [proxmox_download_file.cloud_image[each.key]]
  }

  node_name   = var.node_name
  vm_id       = each.value.vm_id
  name        = each.key
  template    = true
  tags        = ["iac", "image-catalogue"]
  description = "Cloud image template managed by the image catalogue OpenTofu root."

  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  started       = false
  on_boot       = false

  agent {
    enabled = each.value.agent_enabled
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 1024
  }

  efi_disk {
    datastore_id      = var.vm_datastore_id
    type              = "4m"
    pre_enrolled_keys = true
  }

  disk {
    datastore_id = var.vm_datastore_id
    interface    = "scsi0"
    import_from  = proxmox_download_file.cloud_image[each.key].id
    discard      = "on"
    iothread     = true
    size         = each.value.disk_size_gb
    ssd          = true
  }

  initialization {
    datastore_id = var.vm_datastore_id

    user_account {
      username = var.cloud_user
      keys     = sort(tolist(var.cloud_ssh_public_keys))
    }

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  network_device {
    bridge = var.vm_bridge
    model  = "virtio"
  }

  serial_device {
    device = "socket"
  }

  vga {
    type = "serial0"
  }
}

output "cloud_image_templates" {
  description = "VM IDs of the managed cloud image templates, keyed by template name."
  value = {
    for name, template in proxmox_virtual_environment_vm.cloud_template :
    name => template.vm_id
  }
}

output "cloud_image_sources" {
  description = "Publisher-resolved immutable image URLs and SHA-256 checksums."
  value = {
    for name, image in local.cloud_images : name => {
      url             = image.url
      sha256_checksum = image.sha256_checksum
    }
  }
}
