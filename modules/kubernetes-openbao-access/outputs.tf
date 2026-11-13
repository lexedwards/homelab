output "secret_provider_class" {
  description = "Service-owned class reference for read-only inline CSI volumes; contains no delivered values."
  sensitive   = true
  value       = { name = var.provider_class, namespace = var.namespace }
}
