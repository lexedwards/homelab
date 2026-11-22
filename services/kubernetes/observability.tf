variable "cilium_metrics_enabled" {
  description = "Render agent/operator metrics in the existing native Cilium configuration. Does not change first-boot snippets, deploy a collector or authorize a datapath rollout."
  type        = bool
  default     = false
  nullable    = false
}

locals {
  cilium_observability_values = var.cilium_metrics_enabled ? {
    prometheus        = { enabled = true }
    rollOutCiliumPods = true
    operator = merge(local.cilium_bootstrap_values.operator, try(local.service_exposure_values.operator, {}), {
      prometheus  = { enabled = true }
      rollOutPods = true
    })
  } : {}
}

output "cilium_metrics_manifest" {
  description = "Complete private native Cilium configuration, preserving exposure values. Export after an authorized canonical plan/apply; atomically replace the existing manifest only under separate rollout approval."
  sensitive   = true
  value       = var.cilium_metrics_enabled ? local.cilium_config : null
}
