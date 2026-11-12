variable "workers" {
  description = "Worker FQDNs and Proxmox-observed primary NIC MACs, guest-agent MACs and per-interface IPv4 addresses."
  type = map(object({
    fqdn           = string
    primary_mac    = string
    mac_addresses  = list(string)
    ipv4_addresses = list(list(string))
  }))
  nullable  = false
  sensitive = true
}

variable "zone" {
  description = "Existing forward zone shared with the API record."
  type        = string
  nullable    = false
  sensitive   = true
}

variable "ttl" {
  description = "Record TTL shared with the API record."
  type        = number
  nullable    = false
}

variable "cluster_networks" {
  description = "Internal pod/Service ranges that cannot supply node DNS addresses."
  type = object({
    pods     = string
    services = string
  })
  nullable  = false
  sensitive = true
}

variable "reverse_zone" {
  description = "Approved existing reverse zone; null disables PTR ownership."
  type        = string
  default     = null
  sensitive   = true
}
