terraform {
  required_version = ">= 1.6.0"

  required_providers {
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "= 2.4.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "= 2.9.0"
    }
  }
}
