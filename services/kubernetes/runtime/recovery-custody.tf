variable "recovery_custody" {
  description = "Opt-in administrative recovery-record authorization only. Fingerprints bind exact records to the initialized cluster; actual server tokens and S3 values are enrolled out of band and never enter OpenTofu."
  type = object({
    kv_v2_mount              = string
    cluster_uid              = string
    server_token_hash        = string
    backup_credential_sha256 = string
  })
  sensitive = true
  default   = null

  validation {
    condition = var.recovery_custody == null ? true : (
      var.secrets_platform != null &&
      can(regex("^[a-z0-9][a-z0-9-]*$", var.recovery_custody.kv_v2_mount)) &&
      can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.recovery_custody.cluster_uid)) &&
      can(regex("^[0-9a-f]{12}$", var.recovery_custody.server_token_hash)) &&
      can(regex("^[0-9a-f]{64}$", var.recovery_custody.backup_credential_sha256))
    )
    error_message = "Recovery enrollment needs enabled runtime inputs, an exact existing KV-v2 mount, cluster UUID, native twelve-hex server-token fingerprint and sixty-four-hex credential fingerprint. Never supply values."
  }
}

locals {
  recovery_enabled = local.secrets_enabled && nonsensitive(var.recovery_custody != null)
  recovery_records = local.recovery_enabled ? {
    server_token = {
      path   = "${var.recovery_custody.kv_v2_mount}/data/kubernetes/recovery/${var.recovery_custody.cluster_uid}/server-token/${var.recovery_custody.server_token_hash}"
      fields = ["server_token"]
    }
    s3_credentials = {
      path   = "${var.recovery_custody.kv_v2_mount}/data/kubernetes/recovery/${var.recovery_custody.cluster_uid}/s3-credentials/${var.recovery_custody.backup_credential_sha256}"
      fields = ["access_key_id", "secret_access_key"]
    }
  } : {}
}

data "kubernetes_namespace_v1" "recovery_cluster" {
  count = local.recovery_enabled ? 1 : 0
  metadata { name = "kube-system" }
  lifecycle {
    postcondition {
      condition     = self.metadata[0].uid == var.recovery_custody.cluster_uid
      error_message = "Recovery-record authorization must match the already initialized cluster."
    }
  }
}

module "recovery_deployment_access" {
  count        = local.recovery_enabled ? 1 : 0
  source       = "../../../modules/openbao-deployment-access"
  name         = "kubernetes-recovery"
  secret_paths = [for record in local.recovery_records : record.path]
  depends_on   = [data.kubernetes_namespace_v1.recovery_cluster]
}

output "recovery_custody_enrollment" {
  description = "Protected recovery-record schemas and bounded-writer metadata only. No application read policy, credential or record value is created."
  sensitive   = true
  value = local.recovery_enabled ? merge(module.recovery_deployment_access[0].enrollment, {
    address     = local.openbao_endpoint
    cluster_uid = var.recovery_custody.cluster_uid
    records     = local.recovery_records
  }) : null
}
