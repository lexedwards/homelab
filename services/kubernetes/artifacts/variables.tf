variable "s3_endpoint" {
  description = "Published, system-trusted HTTPS S3 origin. Authentication uses AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.s3_endpoint))
    error_message = "Supply a verified HTTPS origin without a path or inline credentials."
  }
}

variable "s3_region" {
  description = "Region published by the object-storage operator."
  type        = string
  default     = "us-east-1"
  nullable    = false
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.s3_region))
    error_message = "Supply a region name."
  }
}

variable "cluster_name" {
  description = "Stable friendly cluster storage/authorization name, optionally including a once-chosen suffix. Renaming is a migration, not VM recovery."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,38}[a-z0-9]$", var.cluster_name))
    error_message = "Use two to forty lowercase name characters, ending in a letter or digit."
  }
}

variable "cluster_uid" {
  description = "Optional observed namespace UID for standalone publication of an existing cluster; identity evidence only, never storage addressing. Automatic bootstrap discovers it in the guest."
  type        = string
  sensitive   = true
  default     = null
  validation {
    condition     = var.cluster_uid == null ? true : can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.cluster_uid))
    error_message = "Supply the actual canonical cluster UUID, not a hostname or a guessed future identity."
  }
}

variable "api_server" {
  description = "Stable, certificate-covered HTTPS Kubernetes API origin included in the exported kubeconfig."
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.api_server))
    error_message = "Supply the stable HTTPS API origin without credentials or a path."
  }
}

variable "openbao_address" {
  description = "Published, system-trusted HTTPS OpenBao origin; authentication uses VAULT_TOKEN."
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.openbao_address))
    error_message = "Supply a verified HTTPS OpenBao origin."
  }
}

variable "approle_mount" {
  description = "Existing platform-owned AppRole mount."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.approle_mount))
    error_message = "Supply one mount name without paths or wildcards."
  }
}

variable "publisher_secret_path" {
  description = "Exact existing KV-v2 data path for AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY; values are enrolled separately."
  type        = string
  sensitive   = true
  validation {
    condition = (
      can(regex("^[a-z][a-z0-9-]*/data/[A-Za-z0-9_/-]+$", var.publisher_secret_path)) &&
      !contains(["sys", "auth", "identity", "cubbyhole"], split("/", var.publisher_secret_path)[0]) &&
      alltrue([for part in split("/", var.publisher_secret_path) : part != ""])
    )
    error_message = "Supply an exact KV-v2 data path without wildcards or traversal."
  }
}
