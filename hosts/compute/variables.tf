variable "proxmox_endpoint" {
  description = "HTTPS endpoint for the compute Proxmox VE API."
  type        = string
  nullable    = false

  validation {
    condition     = startswith(var.proxmox_endpoint, "https://")
    error_message = "proxmox_endpoint must be an HTTPS URL."
  }
}

variable "proxmox_insecure" {
  description = "Disable TLS certificate verification for the Proxmox VE API."
  type        = bool
  default     = false
  nullable    = false
}
