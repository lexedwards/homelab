terraform {
  required_version = ">= 1.9.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "= 0.111.1"
    }
    technitium = {
      source  = "registry.terraform.io/darkhonor/technitium"
      version = "= 1.3.0"
    }
  }
}
