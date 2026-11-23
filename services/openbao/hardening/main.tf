variable "openbao_address" {
  description = "Published verified HTTPS API origin from the hosting root."
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.openbao_address))
    error_message = "Supply an HTTPS origin without credentials, path, query or fragment."
  }
}

variable "identity_metadata_paths" {
  description = "Opt-in exact KV-v2 Kubernetes identity metadata records the administrator may read/update. No wildcards, deletion or secret-value permissions."
  type        = set(string)
  default     = []
  sensitive   = true
  validation {
    condition = alltrue([for path in var.identity_metadata_paths :
      can(regex("^[a-z][a-z0-9-]*/metadata/kubernetes/[a-z][a-z0-9-]{0,38}[a-z0-9]/identity$", path)) &&
      !contains(["sys", "auth", "identity", "cubbyhole"], split("/", path)[0])
    ])
    error_message = "Supply only exact KV-v2 Kubernetes identity metadata paths with a stable cluster-name segment; no data paths or wildcard scopes."
  }
}

locals {
  administrator_policy = join("\n", concat([file("${path.module}/administrator.hcl")], [
    for path in sort(tolist(var.identity_metadata_paths)) :
    "path ${jsonencode(path)} { capabilities = [\"read\", \"update\"] }"
  ]))
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
  policy          = local.administrator_policy

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
