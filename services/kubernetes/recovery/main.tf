provider "vault" {
  address          = var.openbao_address
  skip_tls_verify  = false
  skip_child_token = true
}

locals {
  role_name = "kubernetes-${var.enrollment_name}-bootstrap"
  records   = compact([var.s3_secret_path, var.server_token_path])
}

resource "vault_policy" "reader" {
  name            = "${local.role_name}-read"
  allow_overwrite = false
  policy = join("\n", concat([
    for path in local.records : "path ${jsonencode(path)} { capabilities = [\"read\"] }"
  ], ["path \"auth/token/revoke-self\" { capabilities = [\"update\"] }"]))
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

module "snapshot_value_access" {
  count        = var.mode == "join" ? 0 : 1
  source       = "../../../modules/openbao-deployment-access"
  name         = "k8s-bootstrap-${var.enrollment_name}"
  secret_paths = [var.s3_secret_path]
}

output "enrollment" {
  sensitive = true
  value = {
    address           = var.openbao_address
    auth_mount        = var.approle_mount
    role_name         = vault_approle_auth_backend_role.reader.role_name
    role_id           = vault_approle_auth_backend_role.reader.role_id
    reader_policy     = vault_policy.reader.name
    s3_secret_path    = var.s3_secret_path
    server_token_path = var.server_token_path
  }
}

output "issuer_policy" {
  sensitive = true
  value     = vault_policy.issuer.name
}

output "snapshot_reader" {
  sensitive = true
  value = var.mode == "join" ? null : {
    endpoint = var.backup.endpoint
    region   = var.backup.region
    bucket   = var.backup.bucket
    mode     = var.mode
    key      = var.backup.key
    policy = {
      Version = "2012-10-17"
      Statement = [{
        Effect   = "Allow"
        Action   = var.mode == "create" ? ["s3:ListBucket", "s3:ListBucketVersions"] : ["s3:GetObject"]
        Resource = [var.mode == "create" ? "arn:aws:s3:::${var.backup.bucket}" : "arn:aws:s3:::${var.backup.bucket}/${var.backup.key}"]
      }]
    }
  }
}

output "snapshot_value_enrollment" {
  sensitive = true
  value = var.mode == "join" ? null : merge(module.snapshot_value_access[0].enrollment, {
    address     = var.openbao_address
    secret_path = var.s3_secret_path
    fields      = ["access_key_id", "secret_access_key"]
  })
}
