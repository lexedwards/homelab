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

variable "technitium_zones" {
  description = "Existing unsigned Primary zones keyed by stable opaque labels, not DNS names. Supply every policy value from the reviewed inventory; no zone names or ACLs are inferred from infrastructure."
  type = map(object({
    name                       = string
    type                       = string
    disabled                   = bool
    soa_serial_date_scheme     = bool
    query_access               = string
    query_access_network_acl   = list(string)
    dynamic_update             = string
    dynamic_update_network_acl = list(string)
  }))
  sensitive = true
  nullable  = false

  validation {
    condition = alltrue([
      for zone in values(var.technitium_zones) : try(alltrue([for value in zone : value != null]), false)
    ])
    error_message = "Every adopted zone and all its attributes must be non-null. Use an explicit empty ACL only when the existing ACL is empty."
  }

  validation {
    condition = alltrue([
      for label, zone in var.technitium_zones : can(regex("^[a-z][a-z0-9_]*$", label)) && try(
        zone.type == "Primary" && length(trimspace(zone.name)) > 0 && zone.name == trimspace(zone.name) &&
        contains(["Allow", "Deny", "AllowOnlyPrivateNetworks", "AllowOnlyZoneNameServers", "UseSpecifiedNetworkACL", "AllowZoneNameServersAndUseSpecifiedNetworkACL"], zone.query_access) &&
        contains(["Deny", "Allow", "AllowOnlyZoneNameServers", "UseSpecifiedNetworkACL", "AllowZoneNameServersAndUseSpecifiedNetworkACL"], zone.dynamic_update) &&
        alltrue([for entry in concat(zone.query_access_network_acl, zone.dynamic_update_network_acl) : entry != null && length(trimspace(entry)) > 0]),
        false
      )
    ])
    error_message = "Use stable opaque snake_case labels, existing Primary zone names without surrounding whitespace, valid query/update modes, and ACLs without null or blank entries."
  }

  validation {
    condition = try(
      length(distinct([for zone in values(var.technitium_zones) : lower(trimsuffix(zone.name, "."))])) == length(var.technitium_zones),
      false
    )
    error_message = "Each zone must have exactly one owner; zone names must be unique regardless of case or a trailing dot."
  }
}
