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

resource "incus_storage_volume" "uptime_kuma_data" {
  name         = "uptime-kuma-data"
  pool         = data.incus_storage_pool.default.name
  project      = "default"
  type         = "custom"
  content_type = "filesystem"

  lifecycle {
    prevent_destroy = true
  }
}

resource "incus_instance" "uptime_kuma" {
  name     = "uptime-kuma"
  image    = var.incus_image
  project  = "default"
  profiles = []
  running  = true

  config = {
    "boot.autostart"                       = "true"
    "cloud-init.user-data"                 = trimspace(templatefile("${path.module}/cloud-init/user-data.tftpl", {}))
    "limits.cpu"                           = "1"
    "limits.memory"                        = "1GiB"
    "security.nesting"                     = "true"
    "security.syscalls.intercept.mknod"    = "true"
    "security.syscalls.intercept.setxattr" = "true"
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

  device {
    name = "data"
    type = "disk"

    properties = {
      path   = "/var/lib/uptime-kuma"
      pool   = data.incus_storage_pool.default.name
      source = incus_storage_volume.uptime_kuma_data.name
    }
  }

  wait_for {
    type = "cloud-init"
  }

  exec = {
    "00-check-http" = {
      command = [
        "curl",
        "--fail",
        "--silent",
        "--show-error",
        "--retry", "30",
        "--retry-delay", "2",
        "--retry-all-errors",
        "http://127.0.0.1:3001/",
      ]
      timeout = "2m"
      trigger = "once"
    }
  }
}

output "ipv4_address" {
  description = "IPv4 address reported by Incus for the Uptime Kuma instance."
  sensitive   = true
  value       = incus_instance.uptime_kuma.ipv4_address
}
