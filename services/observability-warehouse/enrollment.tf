variable "warehouse_openbao_access" {
  description = "Non-secret enrollment output published by this service's access root; null leaves existing manual enrollment unchanged."
  type = object({
    address       = string
    auth_mount    = string
    role_name     = string
    role_id       = string
    reader_policy = string
    secret_path   = string
  })
  default   = null
  sensitive = true
  validation {
    condition = var.warehouse_openbao_access == null ? true : (
      can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.warehouse_openbao_access.address)) &&
      can(regex("^[a-z][a-z0-9-]*$", var.warehouse_openbao_access.auth_mount)) &&
      var.warehouse_openbao_access.role_name == "observability-warehouse" &&
      var.warehouse_openbao_access.reader_policy == "observability-warehouse-read" &&
      can(regex("^[A-Za-z0-9-]+$", var.warehouse_openbao_access.role_id)) &&
      can(regex("^[a-z][a-z0-9-]*/data/[A-Za-z0-9_/-]+$", var.warehouse_openbao_access.secret_path)) &&
      !contains(["sys", "auth", "identity", "cubbyhole"], split("/", var.warehouse_openbao_access.secret_path)[0]) &&
      alltrue([for part in split("/", var.warehouse_openbao_access.secret_path) : part != ""])
    )
    error_message = "Supply the unchanged service access-root enrollment object, without secret values."
  }
}

variable "warehouse_ssh_known_hosts_file" {
  description = "Operator-owned verified guest host-key/CA file; required when OpenBao enrollment is enabled."
  type        = string
  default     = null
  sensitive   = true
  validation {
    condition     = var.warehouse_openbao_access == null || var.warehouse_ssh_known_hosts_file != null
    error_message = "SSH enrollment requires an independently verified guest known-hosts file."
  }
}

variable "openbao_issuer_token" {
  description = "Ephemeral credential with only the warehouse issuer policy; needed only for initial enrollment."
  type        = string
  sensitive   = true
  ephemeral   = true
  default     = null
}

variable "warehouse_enrollment_revision" {
  description = "Explicit retry revision for the idempotent enrollment hook; does not rotate an existing SecretID."
  type        = string
  default     = "1"
  nullable    = false
}

resource "terraform_data" "warehouse_enrollment" {
  count = nonsensitive(var.warehouse_openbao_access != null) ? 1 : 0

  triggers_replace = [
    sha256(jsonencode(var.warehouse_openbao_access)),
    filesha256(pathexpand(var.warehouse_ssh_known_hosts_file)),
    var.warehouse_enrollment_revision,
  ]

  depends_on = [proxmox_virtual_environment_vm.observability_warehouse]
  lifecycle {
    replace_triggered_by = [proxmox_virtual_environment_vm.observability_warehouse]
  }

  provisioner "local-exec" {
    command = "bash \"${path.module}/scripts/enroll-warehouse.sh\""
    environment = {
      BAO_ADDR                = var.warehouse_openbao_access.address
      BAO_AUTH_MOUNT          = var.warehouse_openbao_access.auth_mount
      BAO_TOKEN               = var.openbao_issuer_token == null ? "" : var.openbao_issuer_token
      WAREHOUSE_SSH_TARGET    = "${var.cloud_user}@${local.warehouse_ipv4_address}"
      WAREHOUSE_KNOWN_HOSTS   = pathexpand(var.warehouse_ssh_known_hosts_file)
      WAREHOUSE_CONFIG_SHA256 = sha256(jsonencode(var.warehouse_openbao_access))
    }
  }
}
