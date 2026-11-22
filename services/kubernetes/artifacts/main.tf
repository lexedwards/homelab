provider "aws" {
  region                      = var.s3_region
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3 = var.s3_endpoint
  }
}

provider "vault" {
  address          = var.openbao_address
  skip_tls_verify  = false
  skip_child_token = true
}

locals {
  object_key = "rke2/${var.cluster_uid}/kubeconfig.yaml"
  role_name  = "kubernetes-${var.cluster_uid}-kubeconfig"
  publisher_policy = {
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject"]
      Resource = ["arn:aws:s3:::${var.configuration_bucket}/${local.object_key}"]
    }]
  }
}

resource "aws_s3_bucket" "configuration" {
  bucket        = var.configuration_bucket
  force_destroy = false

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = var.configuration_bucket != var.backup_bucket
      error_message = "Configuration artifacts must use a different bucket from etcd backups."
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "configuration" {
  bucket = aws_s3_bucket.configuration.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "configuration" {
  bucket = aws_s3_bucket.configuration.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "vault_policy" "reader" {
  name            = "${local.role_name}-read"
  allow_overwrite = false
  policy          = <<-POLICY
    path ${jsonencode(var.publisher_secret_path)} { capabilities = ["read"] }
    path "auth/token/renew-self" { capabilities = ["update"] }
    path "auth/token/revoke-self" { capabilities = ["update"] }
  POLICY
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
  token_max_ttl           = 3600
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

module "publisher_value_access" {
  source       = "../../../modules/openbao-deployment-access"
  name         = "kubeconfig-${var.cluster_uid}"
  secret_paths = [var.publisher_secret_path]
}

output "publisher" {
  description = "Protected non-secret scope for out-of-band publisher credential issuance; no credential values."
  sensitive   = true
  value = {
    endpoint    = var.s3_endpoint
    region      = var.s3_region
    bucket      = aws_s3_bucket.configuration.bucket
    cluster_uid = var.cluster_uid
    key         = local.object_key
    policy      = local.publisher_policy
  }
}

output "enrollment" {
  description = "Protected public metadata for host enrollment, not a SecretID or application credential."
  sensitive   = true
  value = {
    address       = var.openbao_address
    auth_mount    = var.approle_mount
    role_name     = vault_approle_auth_backend_role.reader.role_name
    role_id       = vault_approle_auth_backend_role.reader.role_id
    reader_policy = vault_policy.reader.name
    secret_path   = var.publisher_secret_path
    publication = {
      endpoint    = var.s3_endpoint
      bucket      = aws_s3_bucket.configuration.bucket
      region      = var.s3_region
      cluster_uid = var.cluster_uid
      api_server  = var.api_server
    }
  }
}

output "issuer_policy" {
  sensitive = true
  value     = vault_policy.issuer.name
}

output "publisher_value_enrollment" {
  description = "Bounded writer authorization and record schema for out-of-band S3 credential enrollment, never values."
  sensitive   = true
  value = merge(module.publisher_value_access.enrollment, {
    address     = var.openbao_address
    secret_path = var.publisher_secret_path
    fields      = ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]
  })
}
