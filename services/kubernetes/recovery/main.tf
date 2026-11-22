provider "vault" {
  address          = var.openbao_address
  skip_tls_verify  = false
  skip_child_token = true
}

locals {
  role_name       = "kubernetes-${var.enrollment_name}-bootstrap"
  identity_writer = "kubernetes-${var.enrollment_name}-identity"
  identity_metadata_path = format("%s/metadata/%s", split("/", var.records.identity_path)[0],
  join("/", slice(split("/", var.records.identity_path), 2, length(split("/", var.records.identity_path)))))
}

resource "vault_policy" "identity_writer" {
  name            = local.identity_writer
  allow_overwrite = false
  policy          = <<-POLICY
    path ${jsonencode(var.records.identity_path)} {
      capabilities = ["create", "update"]
      allowed_parameters = { "data" = [], "options" = [{ "cas" = 0 }] }
      required_parameters = ["data", "options"]
    }
    path "auth/token/revoke-self" { capabilities = ["update"] }
  POLICY
}

resource "vault_token_auth_backend_role" "identity_writer" {
  role_name               = local.identity_writer
  allowed_policies        = [vault_policy.identity_writer.name]
  disallowed_policies     = ["root", "default", "${local.role_name}-read"]
  orphan                  = false
  renewable               = false
  token_no_default_policy = true
  token_explicit_max_ttl  = 60
  token_type              = "service"
}

resource "vault_policy" "reader" {
  name            = "${local.role_name}-read"
  allow_overwrite = false
  policy = join("\n", concat([
    for path in values(var.records) : "path ${jsonencode(path)} { capabilities = [\"read\"] }"
    ], [<<-POLICY
      path ${jsonencode(local.identity_metadata_path)} { capabilities = ["read"] }
      path "auth/token/revoke-self" { capabilities = ["update"] }
      path "auth/token/create/${vault_token_auth_backend_role.identity_writer.role_name}" {
        capabilities = ["update"]
        allowed_parameters = {
          "policies" = [["${vault_policy.identity_writer.name}"]]
          "ttl" = ["60s"]
          "explicit_max_ttl" = ["60s"]
          "renewable" = [false]
          "no_default_policy" = [true]
        }
        required_parameters = ["policies", "ttl", "explicit_max_ttl", "renewable", "no_default_policy"]
      }
    POLICY
  ]))
}

resource "vault_approle_auth_backend_role" "reader" {
  backend                 = var.approle_mount
  role_name               = local.role_name
  bind_secret_id          = true
  secret_id_num_uses      = 0
  secret_id_ttl           = 0
  token_policies          = [vault_policy.reader.name]
  token_no_default_policy = true
  token_ttl               = 900
  token_max_ttl           = 900
  token_type              = "service"
}

resource "vault_policy" "issuer" {
  name            = "${local.role_name}-issuer"
  allow_overwrite = false
  policy          = <<-POLICY
    path "auth/${var.approle_mount}/role/${vault_approle_auth_backend_role.reader.role_name}/secret-id" {
      capabilities = ["update"]
      min_wrapping_ttl = "60s"
      max_wrapping_ttl = "300s"
    }
  POLICY
}

module "configuration_access" {
  source       = "../../../modules/openbao-deployment-access"
  name         = "k8s-profile-${var.enrollment_name}"
  secret_paths = [var.records.config_path]
}

output "enrollment" {
  sensitive = true
  value = merge(var.records, {
    address                = var.openbao_address
    auth_mount             = var.approle_mount
    role_name              = vault_approle_auth_backend_role.reader.role_name
    role_id                = vault_approle_auth_backend_role.reader.role_id
    reader_policy          = vault_policy.reader.name
    identity_token_role    = vault_token_auth_backend_role.identity_writer.role_name
    identity_writer_policy = vault_policy.identity_writer.name
  })
}

output "issuer_policy" {
  sensitive = true
  value     = vault_policy.issuer.name
}

output "configuration_enrollment" {
  sensitive = true
  value = merge(module.configuration_access.enrollment, {
    address     = var.openbao_address
    secret_path = var.records.config_path
  })
}
