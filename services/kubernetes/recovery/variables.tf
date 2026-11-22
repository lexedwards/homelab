variable "openbao_address" {
  type        = string
  sensitive   = true
  description = "Published verified HTTPS OpenBao origin; authenticate through VAULT_TOKEN."
  validation {
    condition     = can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.openbao_address))
    error_message = "Supply a verified HTTPS origin without credentials or paths."
  }
}

variable "approle_mount" {
  type        = string
  description = "Existing platform-owned AppRole mount."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.approle_mount))
    error_message = "Supply one existing mount name."
  }
}

variable "enrollment_name" {
  type        = string
  description = "Exact bootstrap authorization identity; independent of the unavailable cluster's API and future namespace UID."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,38}[a-z0-9]$", var.enrollment_name))
    error_message = "Use a service-owned enrollment name of two to forty characters."
  }
}

variable "mode" {
  type        = string
  description = "Selected empty-datastore lifecycle; never inferred from a failed recovery."
  validation {
    condition     = contains(["create", "join", "restore"], var.mode)
    error_message = "Explicitly select create, join or restore."
  }
}

variable "s3_secret_path" {
  type        = string
  sensitive   = true
  default     = null
  description = "Exact KV-v2 application snapshot-reader record; unused for joining. Values are enrolled outside state."
  validation {
    condition = var.mode == "join" ? var.s3_secret_path == null : try(
      can(regex("^[a-z][a-z0-9-]*/data/[A-Za-z0-9_/-]+$", var.s3_secret_path)) &&
      !strcontains(var.s3_secret_path, "/server-token/") &&
      !contains(["sys", "auth", "identity", "cubbyhole"], split("/", var.s3_secret_path)[0]) &&
    alltrue([for part in split("/", var.s3_secret_path) : part != ""]), false)
    error_message = "Create/restore needs an exact KV-v2 S3-reader record; join must not grant snapshot access."
  }
}

variable "server_token_path" {
  type        = string
  sensitive   = true
  default     = null
  description = "Existing independently protected matching server-token record; never generated or populated by this root."
  validation {
    condition = var.mode == "create" ? var.server_token_path == null : try(
      can(regex("^[a-z][a-z0-9-]*/data/[A-Za-z0-9_/-]+$", var.server_token_path)) &&
      can(regex("/server-token/[0-9a-f]{12}$", var.server_token_path)) &&
      !contains(["sys", "auth", "identity", "cubbyhole"], split("/", var.server_token_path)[0]) &&
    alltrue([for part in split("/", var.server_token_path) : part != ""]), false)
    error_message = "Join/restore needs the existing exact server-token record; create must not adopt an existing token."
  }
}

variable "backup" {
  type = object({
    endpoint = string
    bucket   = string
    region   = string
    key      = optional(string)
  })
  sensitive   = true
  default     = null
  description = "Published existing backup bucket and exact approved restore key; create only lists the bucket to confirm absence. No bucket is managed here."
  validation {
    condition = var.mode == "join" ? var.backup == null : try(
      can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.backup.endpoint)) &&
      can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.backup.bucket)) &&
      can(regex("^[a-z0-9-]+$", var.backup.region)) &&
      (var.mode == "create" ? var.backup.key == null :
    can(regex("^rke2/[0-9a-f-]{36}/homelab-scheduled-[a-z0-9-]+-[0-9]{10,}(\\.zip)?$", var.backup.key))), false)
    error_message = "Supply published backup storage with one exact snapshot key for restore, no key for create, and no backup grant for join."
  }
}
