terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.73.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "= 5.13.0"
    }
  }
}
