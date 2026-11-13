variable "name" {
  type = string
  validation {
    condition = alltrue([for identifier in [var.name, var.auth_mount, var.namespace, var.service_account, var.provider_class, var.token_review_role] :
      can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", identifier))
    ])
    error_message = "Service role/policy, auth mount, namespace, account, class and reviewer role must be exact lowercase DNS labels, not paths or wildcard selectors."
  }
}
variable "auth_mount" { type = string }
variable "openbao_endpoint" {
  type      = string
  sensitive = true
  validation {
    condition     = can(regex("^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?/?$", var.openbao_endpoint))
    error_message = "OpenBao must use a verified HTTPS origin without credentials, query or path."
  }
}
variable "api_audience" {
  type = string
  validation {
    condition     = can(regex("^[^[:space:]]{1,256}$", var.api_audience))
    error_message = "Supply exactly one verified Kubernetes API audience."
  }
}
variable "namespace" { type = string }
variable "service_account" { type = string }
variable "provider_class" { type = string }
variable "token_review_role" { type = string }
variable "files" {
  description = "Service-owned record/field definitions only, never populated secret values. Access applies to whole KV-v2 records."
  type = map(object({
    secret_path = string
    secret_key  = string
  }))
  sensitive = true
  validation {
    condition = length(var.files) > 0 && length(var.files) <= 32 && alltrue([for name, object in var.files :
      can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", name)) &&
      can(regex("^[a-z0-9][a-z0-9-]*/data/[A-Za-z0-9._/-]+$", object.secret_path)) &&
      alltrue([for part in split("/", object.secret_path) : !contains(["", ".", ".."], part)]) &&
      !contains(["sys", "auth", "identity", "cubbyhole"], split("/", object.secret_path)[0]) &&
      can(regex("^[A-Za-z0-9_-]{1,128}$", object.secret_key))
    ])
    error_message = "Declare unique simple filenames, exact KV-v2 data record paths and simple field names; no wildcard, traversal, query or secret values."
  }
}
