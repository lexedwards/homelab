variable "openbao_address" {
  description = "Published verified HTTPS API origin from the hosting root."
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.openbao_address))
    error_message = "Supply an HTTPS origin without credentials, path, query or fragment."
  }
}

variable "configuration_token" {
  description = "Trusted administrative credential supplied ephemerally, never a workload token."
  type        = string
  sensitive   = true
  ephemeral   = true
}

provider "vault" {
  address          = var.openbao_address
  token            = var.configuration_token
  skip_tls_verify  = false
  skip_child_token = true
}

resource "vault_auth_backend" "approle" {
  type = "approle"
  path = "approle"
  lifecycle {
    prevent_destroy = true
  }
}

output "approle_mount" {
  value = vault_auth_backend.approle.path
}
