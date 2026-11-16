variable "openbao_address" {
  description = "Published verified HTTPS OpenBao origin."
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.openbao_address))
    error_message = "Supply an HTTPS origin without credentials, path, query or fragment."
  }
}

variable "approle_mount" {
  description = "Published platform-owned AppRole mount."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.approle_mount))
    error_message = "Use a single mount name without paths or wildcards."
  }
}

variable "secret_path" {
  description = "Exact existing KV-v2 data path containing the two AWS credential fields."
  type        = string
  sensitive   = true
  validation {
    condition = (
      can(regex("^[a-z][a-z0-9-]*/data/[A-Za-z0-9_/-]+$", var.secret_path)) &&
      !contains(["sys", "auth", "identity", "cubbyhole"], split("/", var.secret_path)[0]) &&
      alltrue([for part in split("/", var.secret_path) : part != ""])
    )
    error_message = "Use an exact KV-v2 data path without wildcards or traversal."
  }
}

provider "vault" {
  address          = var.openbao_address
  skip_tls_verify  = false
  skip_child_token = true
}

resource "vault_policy" "reader" {
  name            = "observability-warehouse-read"
  allow_overwrite = false
  policy          = <<-POLICY
    path ${jsonencode(var.secret_path)} { capabilities = ["read"] }
    path "auth/token/renew-self" { capabilities = ["update"] }
    path "auth/token/revoke-self" { capabilities = ["update"] }
  POLICY
}

resource "vault_approle_auth_backend_role" "reader" {
  backend                 = var.approle_mount
  role_name               = "observability-warehouse"
  bind_secret_id          = true
  secret_id_num_uses      = 0
  secret_id_ttl           = 0
  token_policies          = [vault_policy.reader.name]
  token_no_default_policy = true
  token_ttl               = 900
  token_max_ttl           = 3600
  token_type              = "service"
}

resource "vault_policy" "issuer" {
  name            = "observability-warehouse-issuer"
  allow_overwrite = false
  policy          = <<-POLICY
    path "auth/${var.approle_mount}/role/${vault_approle_auth_backend_role.reader.role_name}/secret-id" {
      capabilities = ["update"]
      min_wrapping_ttl = "60s"
      max_wrapping_ttl = "300s"
    }
  POLICY
}

output "enrollment" {
  sensitive = true
  value = {
    address       = var.openbao_address
    auth_mount    = var.approle_mount
    role_name     = vault_approle_auth_backend_role.reader.role_name
    role_id       = vault_approle_auth_backend_role.reader.role_id
    reader_policy = vault_policy.reader.name
    secret_path   = var.secret_path
  }
}

output "issuer_policy" {
  value = vault_policy.issuer.name
}
