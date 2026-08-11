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

variable "root_authorized_keys" {
  description = "Public keys written authoritatively to the QDevice root authorized_keys file."
  type        = list(string)
  nullable    = false
  sensitive   = true

  validation {
    condition = (
      length(var.root_authorized_keys) > 0 &&
      alltrue([
        for key in var.root_authorized_keys :
        length(trimspace(key)) > 0 && !strcontains(key, "\n")
      ])
    )
    error_message = "Provide at least one non-empty, single-line SSH public key."
  }
}
