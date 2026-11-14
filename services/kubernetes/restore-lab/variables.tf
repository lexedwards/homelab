variable "proxmox_endpoint" {
  type        = string
  nullable    = false
  description = "Verified HTTPS Proxmox API origin; authenticate through PROXMOX_VE_API_TOKEN."
  validation {
    condition     = can(regex("^https://[^/@?#]+/?$", var.proxmox_endpoint))
    error_message = "Use a verified HTTPS API origin."
  }
}

variable "proxmox_ssh_username" {
  type        = string
  nullable    = false
  description = "PAM SSH identity for service-owned snippet upload using an SSH agent."
}

variable "host" {
  type = object({
    node                 = string
    ssh_address          = string
    vm_datastore_id      = string
    snippet_datastore_id = string
    bridge               = string
    vlan_id              = number
  })
  nullable    = false
  description = "Approved host placement and bootstrap network; the NIC is disconnected before recovery data arrives."
  validation {
    condition     = contains(["compute", "store"], var.host.node) && var.host.vlan_id >= 1 && var.host.vlan_id <= 4094 && floor(var.host.vlan_id) == var.host.vlan_id
    error_message = "Use a supported host and integer VLAN tag."
  }
}

variable "template" {
  type        = object({ node = string, vm_id = number })
  nullable    = false
  description = "Explicit reviewed Rocky Linux 10 amd64 catalogue template."
}

variable "lab" {
  type = object({
    vm_id      = number
    name       = string
    cloud_user = string
    ssh_keys   = set(string)
  })
  nullable    = false
  description = "Unused scratch identity and administrator; never reuse production guest IDs or node names."
  validation {
    condition     = var.lab.vm_id >= 100 && floor(var.lab.vm_id) == var.lab.vm_id && can(regex("^k8s-restore-[a-z0-9-]+$", var.lab.name)) && length(var.lab.ssh_keys) > 0
    error_message = "An explicit scratch ID, k8s-restore name and administrator keys are required."
  }
}

variable "production_vm_ids" {
  type        = set(number)
  nullable    = false
  description = "Existing Kubernetes VM IDs that this lab must never use."
  validation {
    condition     = length(var.production_vm_ids) > 0
    error_message = "Provide the protected production guest IDs."
  }
}

variable "fenced" {
  type        = bool
  default     = true
  nullable    = false
  description = "Disconnect the virtual NIC. False is allowed only for empty prerequisite provisioning, never after recovery data is staged."
}

variable "allow_unconfined_guest_exec" {
  type        = bool
  default     = false
  nullable    = false
  description = "Explicit lab-only approval for the supported virt_qemu_ga_run_unconfined boolean. Global SELinux must remain enforcing."
}
