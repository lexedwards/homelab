variable "secrets_platform" {
  description = "Opt-in runtime platform ownership after cluster enrollment. Kubeconfig and SSH agent credentials stay out of state; public host keys and approved node UIDs bind worker preparation."
  type = object({
    kubeconfig_path = string
    auth_mount      = string
    api_audience    = string
    workers = map(object({
      node_uid = string
      host_key = string
    }))
  })
  sensitive = true
  default   = null

  validation {
    condition = var.secrets_platform == null ? true : (
      startswith(var.secrets_platform.kubeconfig_path, "/") &&
      can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.secrets_platform.auth_mount)) &&
      can(regex("^[^[:space:]]{1,256}$", var.secrets_platform.api_audience)) &&
      length(var.secrets_platform.workers) == 2 &&
      toset(keys(var.secrets_platform.workers)) == toset([for worker in var.workers : worker.name]) &&
      alltrue([for worker in var.secrets_platform.workers :
        length(worker.node_uid) > 0 &&
        can(regex("^(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+$", worker.host_key))
      ])
    )
    error_message = "Supply an absolute protected kubeconfig path, exact auth mount/API audience and both configured workers' approved node UIDs and pinned public SSH host keys."
  }
}

variable "openbao_admin_token" {
  description = "Short-lived scoped setup credential, supplied only through TF_VAR_openbao_admin_token for plan/apply. Ephemeral: never persisted in state or saved plans; no CLI token-cache fallback."
  type        = string
  sensitive   = true
  ephemeral   = true
  default     = null
  validation {
    condition     = var.secrets_platform == null ? true : try(length(trimspace(var.openbao_admin_token)) > 0, false)
    error_message = "Enabled OpenBao management requires an explicitly injected ephemeral administration token. Do not put it in tfvars, argv or logs."
  }
}

variable "secrets_qualification" {
  description = "Owned synthetic service definition only: exact KV-v2 record path and zero/two replicas per runtime. Actual values are populated outside OpenTofu. Enable only after the driver CRDs are installed."
  type = object({
    secret_path = string
    replicas    = optional(number, 0)
  })
  sensitive = true
  default   = null

  validation {
    condition = var.secrets_qualification == null ? true : (
      var.secrets_platform != null && contains([0, 2], var.secrets_qualification.replicas) &&
      can(regex("^[a-z0-9][a-z0-9-]*/data/[A-Za-z0-9._/-]+$", var.secrets_qualification.secret_path)) &&
      alltrue([for part in split("/", var.secrets_qualification.secret_path) : !contains(["", ".", ".."], part)])
    )
    error_message = "Qualification needs the enabled platform, an exact KV-v2 record path without wildcard/query/traversal, and replicas of zero or two."
  }
}
