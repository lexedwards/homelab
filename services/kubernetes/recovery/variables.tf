variable "openbao_address" {
  type        = string
  sensitive   = true
  description = "Verified HTTPS OpenBao origin; administrative authentication uses VAULT_TOKEN. Never passed to VM assets."
  validation {
    condition     = can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.openbao_address))
    error_message = "Supply a verified HTTPS origin."
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

variable "cluster_name" {
  type        = string
  description = "Stable friendly name shared with the cluster's two dedicated storage buckets; not a lifecycle selector."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,38}[a-z0-9]$", var.cluster_name))
    error_message = "Use two to forty service-owned name characters."
  }
}

variable "records" {
  type = object({
    config_path             = string
    identity_path           = string
    server_token_path       = string
    s3_secret_path          = string
    publication_secret_path = string
  })
  sensitive   = true
  description = "Exact, distinct KV-v2 records for runtime profile, durable cluster identity and the three separately enrolled application credentials. No values."
  validation {
    condition = (length(distinct(values(var.records))) == 5 &&
      !strcontains(var.records.config_path, "/server-token/") && !strcontains(var.records.identity_path, "/server-token/") && alltrue([
        for path in values(var.records) : can(regex("^[a-z][a-z0-9-]*/data/[A-Za-z0-9_/-]+$", path)) &&
        !contains(["sys", "auth", "identity", "cubbyhole"], split("/", path)[0]) && alltrue([for part in split("/", path) : part != ""])
    ]))
    error_message = "Supply five distinct exact KV-v2 data paths, without wildcards or traversal."
  }
}
