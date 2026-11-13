output "api_endpoint" {
  description = "Service-owned verified-HTTPS API origin. Non-secret deployment metadata for approved consumers; no authentication material."
  sensitive   = true
  value       = "https://${var.dns_name}:8200"
}
