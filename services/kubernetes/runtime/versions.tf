terraform {
  required_version = ">= 1.11.0"
  required_providers {
    external = {
      source  = "hashicorp/external"
      version = "= 2.3.5"
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
