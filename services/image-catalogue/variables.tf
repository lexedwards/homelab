variable "proxmox_endpoint" {
  description = "HTTPS endpoint for the store Proxmox VE API."
  type        = string
  nullable    = false
  sensitive   = true

  validation {
    condition     = startswith(var.proxmox_endpoint, "https://")
    error_message = "proxmox_endpoint must be an HTTPS URL."
  }
}

variable "proxmox_api_token" {
  description = "API token used to authenticate with Proxmox VE."
  type        = string
  nullable    = false
  sensitive   = true

  validation {
    condition     = length(trimspace(var.proxmox_api_token)) > 0
    error_message = "proxmox_api_token must not be empty."
  }
}

variable "proxmox_insecure" {
  description = "Disable TLS certificate verification for the Proxmox VE API."
  type        = bool
  default     = false
  nullable    = false
}

variable "proxmox_ssh_username" {
  description = "PAM username used to connect to the Proxmox node over SSH."
  type        = string
  nullable    = false
  sensitive   = true

  validation {
    condition     = length(trimspace(var.proxmox_ssh_username)) > 0
    error_message = "proxmox_ssh_username must not be empty."
  }
}

variable "proxmox_ssh_private_key_file" {
  description = "Path to the private key used for Proxmox SSH authentication."
  type        = string
  nullable    = false
  sensitive   = true

  validation {
    condition     = length(trimspace(var.proxmox_ssh_private_key_file)) > 0
    error_message = "proxmox_ssh_private_key_file must not be empty."
  }
}

variable "node_name" {
  description = "Name of the Proxmox VE node that hosts the image catalogue."
  type        = string
  default     = "store"
  nullable    = false

  validation {
    condition     = length(trimspace(var.node_name)) > 0
    error_message = "node_name must not be empty."
  }
}

variable "import_datastore_id" {
  description = "Proxmox datastore used to download source cloud images."
  type        = string
  default     = "local"
  nullable    = false

  validation {
    condition     = length(trimspace(var.import_datastore_id)) > 0
    error_message = "import_datastore_id must not be empty."
  }
}

variable "vm_datastore_id" {
  description = "Proxmox datastore used for template disks and cloud-init drives."
  type        = string
  nullable    = false

  validation {
    condition     = length(trimspace(var.vm_datastore_id)) > 0
    error_message = "vm_datastore_id must not be empty."
  }
}

variable "vm_bridge" {
  description = "Proxmox bridge attached to template network devices."
  type        = string
  default     = "vmbr0"
  nullable    = false

  validation {
    condition     = length(trimspace(var.vm_bridge)) > 0
    error_message = "vm_bridge must not be empty."
  }
}

variable "cloud_user" {
  description = "Default cloud-init user configured on cloned templates."
  type        = string
  nullable    = false

  validation {
    condition     = length(trimspace(var.cloud_user)) > 0
    error_message = "cloud_user must not be empty."
  }
}

variable "cloud_ssh_public_keys" {
  description = "SSH public keys configured for the default cloud-init user."
  type        = set(string)
  nullable    = false
  sensitive   = true

  validation {
    condition = (
      length(var.cloud_ssh_public_keys) > 0 &&
      alltrue([
        for key in var.cloud_ssh_public_keys :
        length(trimspace(key)) > 0 && !strcontains(key, "\n")
      ])
    )
    error_message = "Provide at least one non-empty, single-line SSH public key."
  }
}

variable "cloud_images" {
  description = "Release channels to resolve and expose as Proxmox VM templates."
  type = map(object({
    vm_id           = number
    release_channel = string
    file_name       = string
    disk_size_gb    = number
    agent_enabled   = optional(bool, true)
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for name in keys(var.cloud_images) :
      can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", name))
    ])
    error_message = "Every cloud image name must be a lowercase DNS-compatible VM name."
  }

  validation {
    condition = alltrue([
      for image in values(var.cloud_images) :
      image.vm_id >= 100 && image.vm_id <= 999999999 && floor(image.vm_id) == image.vm_id
    ])
    error_message = "Every cloud image vm_id must be a whole number from 100 through 999999999."
  }

  validation {
    condition     = length(distinct([for image in values(var.cloud_images) : image.vm_id])) == length(var.cloud_images)
    error_message = "Every cloud image must use a unique vm_id."
  }

  validation {
    condition = alltrue([
      for image in values(var.cloud_images) :
      contains([
        "amazon-linux-2023",
        "fedora-44",
        "rocky-linux-10",
        "ubuntu-26.04",
      ], image.release_channel) &&
      length(trimspace(image.file_name)) > 0 &&
      image.disk_size_gb > 0
    ])
    error_message = "Every cloud image requires a supported release channel, file name, and positive disk size."
  }
}
