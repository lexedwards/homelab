variable "incus_remote" {
  description = "Name of the trusted Incus remote in the local client configuration."
  type        = string
  nullable    = false

  validation {
    condition     = length(trimspace(var.incus_remote)) > 0
    error_message = "incus_remote must not be empty."
  }
}

variable "incus_image" {
  description = "Reviewed Debian 13 ARM64 cloud-image reference for the Incus container."
  type        = string
  nullable    = false

  validation {
    condition     = length(trimspace(var.incus_image)) > 0
    error_message = "incus_image must not be empty."
  }
}

variable "instance_vlan_id" {
  description = "VLAN ID attached to the instance NIC; upstream networking provides DHCP and access policy."
  type        = number
  nullable    = false

  validation {
    condition     = var.instance_vlan_id >= 1 && var.instance_vlan_id <= 4094 && floor(var.instance_vlan_id) == var.instance_vlan_id
    error_message = "instance_vlan_id must be an integer from 1 through 4094."
  }
}

variable "instance_cpu_count" {
  description = "CPU limit for the single-node homelab server."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.instance_cpu_count >= 1 && floor(var.instance_cpu_count) == var.instance_cpu_count
    error_message = "instance_cpu_count must be a positive integer."
  }
}

variable "instance_memory_mib" {
  description = "Memory limit in MiB. Monitor usage as stored data and client load grow."
  type        = number
  default     = 1024
  nullable    = false

  validation {
    condition     = var.instance_memory_mib >= 512 && floor(var.instance_memory_mib) == var.instance_memory_mib
    error_message = "instance_memory_mib must be an integer of at least 512."
  }
}
