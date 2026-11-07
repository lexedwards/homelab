variable "technitium_server_url" {
  description = "Private DNS API base URL through an approved access path. Inject authentication with TECHNITIUM_API_TOKEN."
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition     = can(regex("^https?://[^[:space:]]+$", var.technitium_server_url))
    error_message = "technitium_server_url must be an HTTP(S) API base URL without whitespace."
  }
}

variable "dns_zone" {
  description = "Existing Technitium parent zone. Its lifecycle is not owned by this service."
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition     = length(var.dns_zone) <= 253 && alltrue([for label in split(".", var.dns_zone) : length(label) <= 63]) && can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.dns_zone))
    error_message = "dns_zone must be a lowercase DNS zone without whitespace or a trailing dot."
  }
}

variable "dns_name" {
  description = "Private fully qualified DNS name for the HTTP API and UI. TLS is explicitly deferred."
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition = (
      length(var.dns_name) <= 253 &&
      alltrue([for label in split(".", var.dns_name) : length(label) <= 63]) &&
      can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.dns_name)) &&
      (var.dns_name == var.dns_zone || endswith(var.dns_name, ".${var.dns_zone}"))
    )
    error_message = "dns_name must be a lowercase DNS name within dns_zone, without a trailing dot."
  }
}

variable "dns_ttl" {
  description = "TTL in seconds for the service-owned A record."
  type        = number
  default     = 300
  nullable    = false

  validation {
    condition     = var.dns_ttl >= 0 && var.dns_ttl <= 2147483647 && floor(var.dns_ttl) == var.dns_ttl
    error_message = "dns_ttl must be an integer from 0 through 2147483647."
  }
}
