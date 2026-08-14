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

resource "incus_instance" "tailscale_exit_node" {
  name     = "tailscale-exit-node"
  image    = var.incus_image
  project  = "default"
  profiles = []
  running  = true

  config = {
    "boot.autostart"                            = "true"
    "cloud-init.network-config"                 = trimspace(file("${path.module}/cloud-init/network-config.tftpl"))
    "cloud-init.user-data"                      = trimspace(file("${path.module}/cloud-init/user-data.tftpl"))
    "limits.cpu"                                = "1"
    "limits.memory"                             = "256MiB"
    "linux.sysctl.net.ipv4.ip_forward"          = "1"
    "linux.sysctl.net.ipv6.conf.all.forwarding" = "1"
    "security.nesting"                          = "true"
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
    name = "tun"
    type = "unix-char"

    properties = {
      path   = "/dev/net/tun"
      source = "/dev/net/tun"
    }
  }

  wait_for {
    type = "cloud-init"
  }

  exec = {
    "00-check-tailscale" = {
      command = [
        "/bin/sh",
        "-c",
        "test -c /dev/net/tun && systemctl is-active --quiet tailscaled && test \"$(sysctl -n net.ipv4.ip_forward)\" = 1 && test \"$(sysctl -n net.ipv6.conf.all.forwarding)\" = 1",
      ]
      timeout = "2m"
      trigger = "once"
    }
  }
}

output "ipv4_address" {
  description = "IPv4 address reported by Incus for the Tailscale exit-node instance."
  sensitive   = true
  value       = incus_instance.tailscale_exit_node.ipv4_address
}
