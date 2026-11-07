provider "incus" {
  default_remote = var.incus_remote

  remote {
    name = var.incus_remote
  }
}

locals {
  openbao_version = "2.7.2"
  openbao_sha256  = "f9f40f906aaf673f536e59e45be3f485408b36cdb75697e89bb5201b8545dc46"
  server_config = templatefile("${path.module}/config/openbao.hcl.tftpl", {
    api_addr = "http://${var.dns_name}:8200"
  })
  user_data = templatefile("${path.module}/cloud-init/user-data.tftpl", {
    server_config   = local.server_config
    readiness       = file("${path.module}/scripts/check-ready.py")
    install         = file("${path.module}/scripts/install.sh")
    openbao_version = local.openbao_version
    openbao_sha256  = local.openbao_sha256
  })
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

resource "incus_storage_volume" "openbao_data" {
  name         = "openbao-data"
  pool         = data.incus_storage_pool.default.name
  project      = "default"
  type         = "custom"
  content_type = "filesystem"

  lifecycle {
    prevent_destroy = true
  }
}

resource "incus_instance" "openbao" {
  name     = "openbao"
  image    = var.incus_image
  project  = "default"
  profiles = []
  running  = true

  config = {
    "boot.autostart"       = "true"
    "cloud-init.user-data" = local.user_data
    "limits.cpu"           = tostring(var.instance_cpu_count)
    "limits.memory"        = "${var.instance_memory_mib}MiB"
    "limits.memory.swap"   = "false"
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

  device {
    name = "data"
    type = "disk"

    properties = {
      path   = "/opt/openbao/data"
      pool   = data.incus_storage_pool.default.name
      source = incus_storage_volume.openbao_data.name
    }
  }

  wait_for {
    type = "cloud-init"
  }

  exec = {
    "00-check-server" = {
      command = ["python3", "/usr/local/lib/openbao/check-ready.py"]
      timeout = "2m"
      trigger = "once"
    }
  }
}

output "ipv4_address" {
  description = "IPv4 address reported by Incus for the OpenBao instance. Reserve it upstream before relying on DNS."
  sensitive   = true
  value       = incus_instance.openbao.ipv4_address
}
