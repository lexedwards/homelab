terraform {
  required_version = ">= 1.9.0"
  required_providers {
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "= 2.4.1"
    }
    proxmox = {
      source  = "bpg/proxmox"
      version = "= 0.111.1"
    }
  }
}
