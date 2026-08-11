variable "instance_id" {
  description = "Unique cloud-init identity for this installation."
  type        = string
  default     = "micro-node"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,62}$", var.instance_id))
    error_message = "The instance ID must use lowercase letters, numbers, and hyphens."
  }
}

variable "hostname_prefix" {
  description = "Prefix for the hostname derived from the parent interface MAC address."
  type        = string
  default     = "micro-node"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9-]{0,56}[a-z0-9])?$", var.hostname_prefix))
    error_message = "The hostname prefix must use lowercase letters, numbers, and hyphens."
  }
}

variable "parent_interface" {
  description = "Physical interface connected to the tagged switch uplink."
  type        = string
  default     = "eth0"
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9_.:-]+$", var.parent_interface))
    error_message = "The parent interface must use a valid network interface name."
  }
}

variable "admin_username" {
  description = "Non-root account used for SSH and Incus administration."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.admin_username))
    error_message = "The administrator username must use safe Linux account syntax."
  }
}

variable "admin_authorized_keys" {
  description = "SSH public keys authorized for the administrator."
  type        = list(string)
  nullable    = false

  validation {
    condition = (
      length(var.admin_authorized_keys) > 0 &&
      alltrue([
        for key in var.admin_authorized_keys :
        length(trimspace(key)) > 0 && !strcontains(key, "\n")
      ])
    )
    error_message = "Provide at least one non-empty, single-line SSH public key."
  }
}

variable "management_vlan_id" {
  description = "VLAN carrying host management traffic."
  type        = number
  nullable    = false

  validation {
    condition = (
      var.management_vlan_id >= 1 &&
      var.management_vlan_id <= 4094 &&
      floor(var.management_vlan_id) == var.management_vlan_id
    )
    error_message = "The management VLAN must be an integer from 1 through 4094."
  }
}

variable "management_address_cidr" {
  description = "Static IPv4 address and prefix for the management VLAN interface."
  type        = string
  nullable    = false

  validation {
    condition = (
      can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$", var.management_address_cidr)) &&
      can(cidrhost(var.management_address_cidr, 0))
    )
    error_message = "The management address must be valid IPv4 CIDR notation."
  }
}

variable "gateway_ipv4" {
  description = "Default IPv4 gateway for the host."
  type        = string
  nullable    = false

  validation {
    condition = (
      can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", var.gateway_ipv4)) &&
      can(cidrhost("${var.gateway_ipv4}/32", 0))
    )
    error_message = "The gateway must be a valid IPv4 address."
  }
}

variable "dns_servers" {
  description = "DNS resolvers used by the host."
  type        = list(string)
  nullable    = false

  validation {
    condition = (
      length(var.dns_servers) > 0 &&
      alltrue([
        for server in var.dns_servers :
        can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", server)) && can(cidrhost("${server}/32", 0))
      ])
    )
    error_message = "Provide at least one valid IPv4 DNS server."
  }
}
