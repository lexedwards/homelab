variable "cluster_api" {
  description = "Reviewed cluster connection: protected kubeconfig plus published infrastructure metadata. SSH user and worker cohort are required only for worker prerequisites. No state or credential values are imported."
  type = object({
    kubeconfig_path = string
    api_host        = string
    ssh_user        = optional(string)
    workers         = optional(set(string), [])
  })
  sensitive = true
  default   = null
  validation {
    condition = var.cluster_api == null ? true : (
      startswith(var.cluster_api.kubeconfig_path, "/") &&
      can(regex("^https://[A-Za-z0-9.-]+:6443$", var.cluster_api.api_host))
    )
    error_message = "Supply an absolute protected kubeconfig path and the stable verified HTTPS API origin on its native port."
  }
}

locals {
  cluster_connection = var.cluster_api == null ? {
    kubeconfig_path = null
    api_host        = null
    ssh_user        = null
    workers         = toset([])
  } : var.cluster_api
}

provider "kubernetes" {
  config_path = local.cluster_connection.kubeconfig_path
  host        = local.cluster_connection.api_host
  insecure    = false
}
