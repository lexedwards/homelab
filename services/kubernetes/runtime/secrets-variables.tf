variable "secrets_platform" {
  description = "Opt-in API runtime ownership in its canonical state after cluster enrollment. Credentials stay out of state; public host keys and approved node UIDs bind worker preparation."
  type = object({
    auth_mount   = string
    api_audience = string
    workers = map(object({
      node_uid = string
      host_key = string
    }))
  })
  sensitive = true
  default   = null

  validation {
    condition = var.secrets_platform == null ? true : try(
      var.cluster_api != null &&
      can(regex("^[a-z_][a-z0-9_-]*$", var.cluster_api.ssh_user)) &&
      can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.secrets_platform.auth_mount)) &&
      can(regex("^[^[:space:]]{1,256}$", var.secrets_platform.api_audience)) &&
      length(var.secrets_platform.workers) > 0 &&
      toset(keys(var.secrets_platform.workers)) == var.cluster_api.workers &&
      alltrue([for worker in var.secrets_platform.workers :
        length(worker.node_uid) > 0 &&
        can(regex("^(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+$", worker.host_key))
      ]),
    false)
    error_message = "Supply common API/SSH metadata, an exact auth mount/audience and the full nonempty worker cohort's approved node UIDs and pinned SSH host keys."
  }
}

variable "openbao_endpoint_file" {
  description = "Absolute path to the privately published JSON api_endpoint output from OpenBao. This consumes its explicit interface, not its state or implementation. Required when the platform is enabled."
  type        = string
  sensitive   = true
  default     = null
  validation {
    condition = var.secrets_platform == null ? true : try(
      startswith(var.openbao_endpoint_file, "/") &&
      can(regex("^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?$", jsondecode(file(var.openbao_endpoint_file)))), false
    )
    error_message = "Supply a published JSON api_endpoint file containing only a verified HTTPS origin without credentials, path or query. Do not point at another service's state."
  }
}
