terraform {
  required_version = ">= 1.11.0"
  required_providers {
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
