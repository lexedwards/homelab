variable "openbao_address" {
  description = "Published verified HTTPS API origin from the init root."
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition     = can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.openbao_address))
    error_message = "Supply an HTTPS origin without credentials, path, query or fragment."
  }
}

variable "operator_username" {
  description = "Named personal administrator, enrolled outside OpenTofu before import."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9_][a-z0-9_.-]*$", var.operator_username))
    error_message = "Use a lowercase username without paths or wildcards."
  }
}

variable "userpass_mount" {
  description = "Published userpass_mount output from the hardening root."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.userpass_mount))
    error_message = "Supply one mount name without paths or wildcards."
  }
}

variable "administrator_policy" {
  description = "Published administrator_policy output from the hardening root."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.administrator_policy))
    error_message = "Supply the administrative policy name without paths or wildcards."
  }
}

provider "vault" {
  address          = var.openbao_address
  skip_tls_verify  = false
  skip_child_token = true
}

resource "vault_generic_endpoint" "operator" {
  path                 = "auth/${var.userpass_mount}/users/${var.operator_username}"
  ignore_absent_fields = true
  disable_delete       = true
  data_json = jsonencode({
    token_policies          = [var.administrator_policy]
    token_no_default_policy = true
    token_ttl               = 3600
    token_max_ttl           = 28800
    token_type              = "service"
  })

  lifecycle {
    prevent_destroy = true
  }
}
