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

locals {
  technitium_version = "15.6.2"
  technitium_sha256  = "51f2d4ebaf156a85035e820afde5e1d428f1920a37d7f0c65203fb1766917e08"
  dotnet_version     = "10.0.15-1"
}

data "cloudinit_config" "user_data" {
  gzip          = false
  base64_encode = false

  part {
    filename     = "technitium-cloud-config.yaml"
    content_type = "text/cloud-config"
    content = templatefile("${path.module}/cloud-init/user-data.tftpl", {
      signing_key        = file("${path.module}/config/microsoft-signing-key.asc")
      service_unit       = file("${path.module}/config/dns.service")
      install_archive    = file("${path.module}/scripts/install-archive.sh")
      technitium_version = local.technitium_version
      technitium_sha256  = local.technitium_sha256
      dotnet_version     = local.dotnet_version
    })
  }
}

resource "incus_instance" "technitium_dns" {
  name     = "technitium-dns"
  image    = var.incus_image
  project  = "default"
  profiles = []
  running  = true

  config = {
    "boot.autostart"       = "true"
    "cloud-init.user-data" = data.cloudinit_config.user_data.rendered
    "limits.cpu"           = "1"
    "limits.memory"        = "512MiB"
    "raw.apparmor"         = "signal (send),"
    "security.nesting"     = "true"
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
      name    = "eth0"
      nictype = "bridged"
      parent  = data.incus_network.br0.name
      vlan    = tostring(var.instance_vlan_id)
    }
  }

  wait_for {
    type = "cloud-init"
  }
}

output "ipv4_address" {
  description = "IPv4 address reported by Incus for the Technitium DNS instance."
  sensitive   = true
  value       = incus_instance.technitium_dns.ipv4_address
}
