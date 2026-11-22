variable "cluster_api" {
  description = "Optional protected kubeconfig for API-managed configuration independent of OpenBao integration. Null preserves secrets_platform's existing connection."
  type = object({
    kubeconfig_path = string
  })
  sensitive = true
  default   = null
  validation {
    condition     = var.cluster_api == null ? true : startswith(var.cluster_api.kubeconfig_path, "/")
    error_message = "Supply an absolute protected kubeconfig path."
  }
}

variable "observability" {
  description = "Opt-in metrics collection. Published ingestion origin, exact collector IPv4/port, DNS resolver and reviewed node/API networks are private inputs, not cross-service state reads."
  type = object({
    cluster_name        = string
    warehouse_url       = string
    warehouse_ipv4      = string
    warehouse_port      = number
    dns_ipv4            = string
    node_ipv4_addresses = set(string)
    api_ipv4_addresses  = set(string)
    allow_plaintext     = optional(bool, false)
  })
  sensitive = true
  default   = null

  validation {
    condition = var.observability == null ? true : (
      (var.cluster_api != null || var.secrets_platform != null) &&
      can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$", var.observability.cluster_name)) &&
      can(regex("^https?://[a-z0-9]([a-z0-9.-]*[a-z0-9])?:[0-9]{1,5}$", var.observability.warehouse_url)) &&
      (startswith(var.observability.warehouse_url, "https://") || var.observability.allow_plaintext) &&
      var.observability.warehouse_port >= 1 && var.observability.warehouse_port <= 65535 &&
      floor(var.observability.warehouse_port) == var.observability.warehouse_port &&
      try(tonumber(regex(":([0-9]+)$", var.observability.warehouse_url)[0]) == var.observability.warehouse_port, false) &&
      length(var.observability.node_ipv4_addresses) > 0 && length(var.observability.api_ipv4_addresses) > 0 &&
      alltrue([for address in concat(
        [var.observability.warehouse_ipv4, var.observability.dns_ipv4],
        tolist(var.observability.node_ipv4_addresses), tolist(var.observability.api_ipv4_addresses)
        ) : can(cidrnetmask("${address}/32")) && try(cidrhost("${address}/32", 0) == address, false)
      ])
    )
    error_message = "Observability requires cluster API access, a bounded cluster identity, a credential-free HTTP(S) origin with matching port, explicit plaintext approval for HTTP, and exact IPv4 endpoints."
  }
}
