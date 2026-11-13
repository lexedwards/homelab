output "runtime_connection" {
  description = "Non-secret connection/placement metadata for the separate API runtime root. No kubeconfig, certificate keys, tokens or delivered values."
  sensitive   = true
  value = {
    api_host = "https://${var.api_dns.name}:6443"
    ssh_user = var.cloud_user
    workers  = sort([for worker in var.workers : worker.name])
  }
}
