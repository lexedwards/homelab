variable "cluster_api" {
  description = "Protected administrator kubeconfig and the reviewed stable API origin; not credential values."
  type        = object({ kubeconfig_path = string, api_host = string })
  sensitive   = true
  validation {
    condition     = startswith(var.cluster_api.kubeconfig_path, "/") && can(regex("^https://[A-Za-z0-9.-]+:6443$", var.cluster_api.api_host))
    error_message = "Supply an absolute protected kubeconfig path and the verified stable API origin."
  }
}

variable "qualification" {
  description = "Explicit synthetic secret-delivery contract. Enable only after the runtime CSI CRDs and Kata prerequisites are ready. Values stay outside state."
  type = object({
    openbao_address = string
    auth_mount      = string
    api_audience    = string
    secret_path     = string
    replicas        = optional(number, 0)
  })
  sensitive = true
  validation {
    condition = (
      can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.qualification.openbao_address)) &&
      can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.qualification.auth_mount)) &&
      can(regex("^[^[:space:]]{1,256}$", var.qualification.api_audience)) &&
      contains([0, 2], var.qualification.replicas) &&
      can(regex("^[a-z0-9][a-z0-9-]*/data/[A-Za-z0-9._/-]+$", var.qualification.secret_path)) &&
      !contains(["sys", "auth", "identity", "cubbyhole"], split("/", var.qualification.secret_path)[0]) &&
      alltrue([for part in split("/", var.qualification.secret_path) : !contains(["", ".", ".."], part)])
    )
    error_message = "Supply the existing verified platform endpoint/auth contract, one exact non-reserved KV-v2 record and zero or two replicas."
  }
}
