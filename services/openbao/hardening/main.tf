variable "openbao_address" {
  description = "Published verified HTTPS API origin from the hosting root."
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.openbao_address))
    error_message = "Supply an HTTPS origin without credentials, path, query or fragment."
  }
}

provider "vault" {
  address          = var.openbao_address
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

resource "vault_auth_backend" "userpass" {
  type = "userpass"
  path = "userpass"

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_policy" "administrator" {
  name            = "openbao-administrator"
  allow_overwrite = false
  policy          = file("${path.module}/administrator.hcl")

  lifecycle {
    prevent_destroy = true
  }
}

output "approle_mount" {
  value = vault_auth_backend.approle.path
}

output "userpass_mount" {
  value = vault_auth_backend.userpass.path
}

output "administrator_policy" {
  value = vault_policy.administrator.name
}
