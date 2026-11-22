variable "bootstrap_access" {
  description = "Non-secret recovery-root enrollment output. When supplied, apply introduces OpenBao access over verified SSH after provisioning; never included in VM installation assets."
  type = object({
    address                 = string
    auth_mount              = string
    role_name               = string
    role_id                 = string
    reader_policy           = string
    identity_token_role     = string
    identity_writer_policy  = string
    config_path             = string
    identity_path           = string
    server_token_path       = string
    s3_secret_path          = string
    publication_secret_path = string
  })
  default   = null
  sensitive = true
  validation {
    condition = var.bootstrap_access == null ? true : try(
      can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.bootstrap_access.address)) &&
      can(regex("^[a-z][a-z0-9-]*$", var.bootstrap_access.auth_mount)) &&
      can(regex("^kubernetes-[a-z0-9-]+-bootstrap$", var.bootstrap_access.role_name)) &&
      can(regex("^[A-Za-z0-9-]+$", var.bootstrap_access.role_id)) &&
      var.bootstrap_access.reader_policy == "${var.bootstrap_access.role_name}-read" &&
      var.bootstrap_access.identity_token_role == "${trimsuffix(var.bootstrap_access.role_name, "-bootstrap")}-identity" &&
      var.bootstrap_access.identity_writer_policy == var.bootstrap_access.identity_token_role &&
      length(distinct([for key, value in var.bootstrap_access : value if endswith(key, "_path")])) == 5 &&
      alltrue([for key, value in var.bootstrap_access :
        can(regex("^[a-z][a-z0-9-]*/data/[A-Za-z0-9_/-]+$", value)) &&
        !contains(["sys", "auth", "identity", "cubbyhole"], split("/", value)[0]) &&
        alltrue([for part in split("/", value) : part != ""])
        if endswith(key, "_path")
      ]), false
    )
    error_message = "Supply the unchanged recovery-root enrollment output with five distinct exact KV-v2 paths, not credential values."
  }
  validation {
    condition     = var.bootstrap_access == null || var.publication_access == null
    error_message = "Bootstrap completion owns publication; do not also enable the independent publication enrollment hook."
  }
}

variable "bootstrap_ssh_known_hosts_file" {
  description = "Operator-owned independently verified guest host-key/CA file; required for automatic bootstrap enrollment."
  type        = string
  default     = null
  sensitive   = true
  validation {
    condition     = var.bootstrap_access == null || var.bootstrap_ssh_known_hosts_file != null
    error_message = "Automatic bootstrap enrollment requires an independently verified guest known-hosts file."
  }
}

variable "bootstrap_issuer_token" {
  description = "Ephemeral exact-role wrapped-SecretID issuer token; needed only on initial enrollment, never an administrator or application credential."
  type        = string
  default     = null
  sensitive   = true
  ephemeral   = true
}

variable "bootstrap_enrollment_revision" {
  description = "Retry the apply-time enrollment hook without changing VM assets or rotating a matching SecretID."
  type        = string
  default     = "1"
  nullable    = false
}

resource "terraform_data" "bootstrap_enrollment" {
  count = nonsensitive(var.bootstrap_access != null) ? 1 : 0

  triggers_replace = [
    sha256(jsonencode(var.bootstrap_access)),
    filesha256(pathexpand(var.bootstrap_ssh_known_hosts_file)),
    var.bootstrap_enrollment_revision,
  ]

  depends_on = [proxmox_virtual_environment_vm.control_plane, technitium_record.api]
  lifecycle {
    replace_triggered_by = [proxmox_virtual_environment_vm.control_plane]
  }

  provisioner "local-exec" {
    command = "bash \"${path.module}/scripts/enroll-control-plane.sh\""
    environment = {
      BAO_ADDR                        = var.bootstrap_access.address
      BAO_AUTH_MOUNT                  = var.bootstrap_access.auth_mount
      BAO_TOKEN                       = var.bootstrap_issuer_token == null ? "" : var.bootstrap_issuer_token
      PUBLICATION_ROLE                = var.bootstrap_access.role_name
      CONTROL_PLANE_CREDENTIAL_HELPER = "bootstrap-credentials"
      CONTROL_PLANE_SSH_TARGET        = "${var.cloud_user}@${local.primary_ipv4}"
      CONTROL_PLANE_KNOWN_HOSTS       = pathexpand(var.bootstrap_ssh_known_hosts_file)
      PUBLICATION_CONFIG_SHA256       = sha256(jsonencode(var.bootstrap_access))
      PUBLICATION_CONFIGURATION       = jsonencode(var.bootstrap_access)
    }
  }
}
