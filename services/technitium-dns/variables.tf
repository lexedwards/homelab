variable "incus_remote" {
  description = "Name of the trusted Incus remote in the local Incus client configuration."
  type        = string
  nullable    = false

  validation {
    condition     = length(trimspace(var.incus_remote)) > 0
    error_message = "incus_remote must not be empty."
  }
}

variable "incus_image" {
  description = "Cloud image used by the Incus instance."
  type        = string
  default     = "images:debian/13/cloud"
  nullable    = false

  validation {
    condition     = length(trimspace(var.incus_image)) > 0
    error_message = "incus_image must not be empty."
  }
}

variable "instance_vlan_id" {
  description = "VLAN ID attached to the instance NIC."
  type        = number
  nullable    = false

  validation {
    condition     = var.instance_vlan_id >= 1 && var.instance_vlan_id <= 4094 && floor(var.instance_vlan_id) == var.instance_vlan_id
    error_message = "instance_vlan_id must be an integer from 1 through 4094."
  }
}

variable "technitium_server_url" {
  description = "Private API base URL using verified HTTPS or a separately reviewed secure access path."
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition     = can(regex("^https?://[^[:space:]]+$", var.technitium_server_url))
    error_message = "technitium_server_url must be an HTTP(S) API base URL without whitespace."
  }
}

variable "technitium_settings" {
  description = "Existing server settings from the reviewed inventory; supply every value explicitly, with no provider-default fallback."
  type = object({
    dnssec_validation                = bool
    recursion                        = string
    recursion_network_acl            = list(string)
    qname_minimization               = bool
    randomize_name                   = bool
    log_queries                      = bool
    logging_type                     = string
    max_log_file_days                = number
    enable_blocking                  = bool
    allow_txt_blocking_report        = bool
    blocking_bypass_list             = list(string)
    blocking_type                    = string
    blocking_answer_ttl              = number
    custom_blocking_addresses        = list(string)
    block_list_urls                  = list(string)
    block_list_update_interval_hours = number
    serve_stale                      = bool
    forwarders                       = list(string)
    forwarder_protocol               = string
    enable_dns_over_tls              = bool
    enable_dns_over_https            = bool
    udp_payload_size                 = number
    cache_minimum_record_ttl         = number
    cache_maximum_record_ttl         = number
    zone_transfer_allowed_networks   = list(string)
    notify_allowed_networks          = list(string)
  })
  sensitive = true
  nullable  = false

  validation {
    condition     = alltrue([for value in var.technitium_settings : value != null])
    error_message = "Every adopted setting must be non-null. Use an explicit empty list only when the existing server list is empty."
  }
}
