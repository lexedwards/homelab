terraform {
  required_version = ">= 1.9.0"

  required_providers {
    incus = {
      source  = "lxc/incus"
      version = "= 1.1.1"
    }
    technitium = {
      source  = "registry.terraform.io/darkhonor/technitium"
      version = "= 1.3.0"
    }
  }
}
