provider "incus" {
  default_remote = var.incus_remote

  remote {
    name = var.incus_remote
  }
}

data "incus_storage_pool" "default" {
  name = "default"

  lifecycle {
    postcondition {
      condition     = self.driver == "dir"
      error_message = "The cloud-init-created default pool must use the dir driver."
    }
  }
}

data "incus_network" "br0" {
  name    = "br0"
  project = "default"

  lifecycle {
    postcondition {
      condition     = self.type == "bridge" && !self.managed
      error_message = "br0 must be an unmanaged host bridge prepared by cloud-init."
    }
  }
}

resource "incus_instance" "proxmox_qdevice" {
  name     = "proxmox-qdevice"
  image    = var.incus_image
  project  = "default"
  profiles = []
  running  = true

  lifecycle {
    precondition {
      condition = (
        length(var.root_authorized_keys) > 0 &&
        alltrue([
          for key in var.root_authorized_keys :
          can(regex("^ssh-[^ ]+ [A-Za-z0-9+/]+={0,3}(?: .*)?$", trimspace(key)))
        ])
      )
      error_message = "Replace every QDevice key placeholder with a valid single-line SSH public key before planning the instance."
    }
  }

  config = {
    "boot.autostart"       = "true"
    "cloud-init.user-data" = trimspace(templatefile("${path.module}/cloud-init/user-data.tftpl", {}))
    "limits.cpu"           = "1"
    "limits.memory"        = "256MiB"
  }

  device {
    name = "root"
    type = "disk"

    properties = {
      path = "/"
      pool = data.incus_storage_pool.default.name
    }
  }

  device {
    name = "eth0"
    type = "nic"

    properties = {
      nictype = "bridged"
      parent  = data.incus_network.br0.name
      vlan    = tostring(var.instance_vlan_id)
    }
  }

  file {
    content            = "${join("\n", [for key in var.root_authorized_keys : trimspace(key)])}\n"
    target_path        = "/root/.ssh/authorized_keys"
    uid                = 0
    gid                = 0
    mode               = "0600"
    directory_mode     = "0700"
    create_directories = true
  }

  wait_for {
    type = "cloud-init"
  }
}

output "ipv4_address" {
  description = "IPv4 address reported by Incus for the QDevice instance."
  sensitive   = true
  value       = incus_instance.proxmox_qdevice.ipv4_address
}
