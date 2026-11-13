variable "name" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.name)) && !contains(["root", "default"], var.name)
    error_message = "Use an exact non-reserved service name without paths or wildcards."
  }
}

variable "secret_paths" {
  description = "Exact service-owned KV-v2 records the deployment token may create/update. No reads, listing, deletion or configuration permissions."
  type        = set(string)
  sensitive   = true
  validation {
    condition = length(var.secret_paths) > 0 && length(var.secret_paths) <= 32 && alltrue([for path in var.secret_paths :
      can(regex("^[a-z0-9][a-z0-9-]*/data/[A-Za-z0-9._/-]+$", path)) &&
      !contains(["sys", "auth", "identity", "cubbyhole"], split("/", path)[0]) &&
      alltrue([for part in split("/", path) : !contains(["", ".", ".."], part)])
    ])
    error_message = "Declare explicit KV-v2 record paths without wildcards, traversal or reserved mounts."
  }
}
