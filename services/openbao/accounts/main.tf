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

variable "warehouse_secret_path" {
  description = "Exact KV-v2 data path for personal warehouse credential create/update/read access; null disables this grant."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition = var.warehouse_secret_path == null ? true : (
      can(regex("^[a-z][a-z0-9-]*/data/[A-Za-z0-9_/-]+$", var.warehouse_secret_path)) &&
      !contains(["sys", "auth", "identity", "cubbyhole"], split("/", var.warehouse_secret_path)[0]) &&
      alltrue([for part in split("/", var.warehouse_secret_path) : part != ""])
    )
    error_message = "Use null or one exact KV-v2 data path without wildcards or traversal."
  }
}

provider "vault" {
  address          = var.openbao_address
  skip_tls_verify  = false
  skip_child_token = true
}

resource "vault_policy" "warehouse_credentials" {
  count = nonsensitive(var.warehouse_secret_path == null) ? 0 : 1

  name            = "openbao-warehouse-credential-editor"
  allow_overwrite = false
  policy          = <<-POLICY
    path ${jsonencode(var.warehouse_secret_path)} {
      capabilities = ["create", "update", "read"]
    }
  POLICY

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_generic_endpoint" "operator" {
  path                 = "auth/${var.userpass_mount}/users/${var.operator_username}"
  ignore_absent_fields = true
  disable_delete       = true
  data_json = jsonencode({
    token_policies          = concat([var.administrator_policy], vault_policy.warehouse_credentials[*].name)
    token_no_default_policy = true
    token_ttl               = 3600
    token_max_ttl           = 28800
    token_type              = "service"
  })

  lifecycle {
    prevent_destroy = true
  }
}
