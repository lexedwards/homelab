terraform {
  required_version = ">= 1.6.0"

  required_providers {
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "= 2.4.1"
    }
    incus = {
      source  = "lxc/incus"
      version = "= 1.1.1"
    }
  }
}
