terraform {
  required_version = ">= 1.11.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "= 0.111.1"
    }
    technitium = {
      source  = "registry.terraform.io/darkhonor/technitium"
      version = "= 1.3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.5.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "= 5.13.0"
    }
  }
}
