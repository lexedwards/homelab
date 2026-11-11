variable "proxmox_endpoint" {
  description = "HTTPS Proxmox API endpoint; authentication uses PROXMOX_VE_API_TOKEN."
  type        = string
  nullable    = false
  sensitive   = true
  validation {
    condition     = can(regex("^https://[^/]+", var.proxmox_endpoint))
    error_message = "proxmox_endpoint must be an HTTPS URL."
  }
}

variable "proxmox_insecure" {
  description = "Disable Proxmox certificate verification only for an explicitly approved exception."
  type        = bool
  default     = false
  nullable    = false
}

variable "proxmox_ssh_username" {
  description = "PAM SSH username for node-side snippet upload through the local SSH agent."
  type        = string
  nullable    = false
  sensitive   = true
  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]*$", var.proxmox_ssh_username))
    error_message = "proxmox_ssh_username must be a Linux username, without a realm suffix."
  }
}

variable "proxmox_nodes" {
  description = "Private host upload addresses, snippet/VM datastores and bridges."
  type = map(object({
    ssh_address          = string
    snippet_datastore_id = string
    vm_datastore_id      = string
    vm_bridge            = string
  }))
  nullable  = false
  sensitive = true
  validation {
    condition = contains(keys(var.proxmox_nodes), "compute") && alltrue([
      for name, node in var.proxmox_nodes : contains(["compute", "store"], name) &&
      can(regex("^[A-Za-z0-9.-]+$", node.ssh_address)) &&
      alltrue([for value in [node.snippet_datastore_id, node.vm_datastore_id, node.vm_bridge] : can(regex("^[A-Za-z0-9_.-]+$", value))])
    ])
    error_message = "proxmox_nodes must use compute/store keys with valid SSH addresses, datastores and bridges."
  }
}

variable "template" {
  description = "Reviewed Rocky Linux 10 amd64 template identity."
  type = object({
    vm_id     = number
    node_name = string
  })
  nullable  = false
  sensitive = true
  validation {
    condition     = floor(var.template.vm_id) == var.template.vm_id && var.template.vm_id >= 100 && var.template.vm_id <= 999999999 && contains(["compute", "store"], var.template.node_name)
    error_message = "template requires an explicit VM ID and compute/store source node."
  }
}

variable "control_plane" {
  description = "Initial server VM ID/name. Proxmox manages its NIC MAC; reserve the observed DHCP lease upstream."
  type = object({
    vm_id = number
    name  = string
  })
  nullable  = false
  sensitive = true
  validation {
    condition = (
      var.control_plane.vm_id >= 100 && var.control_plane.vm_id <= 999999999 && floor(var.control_plane.vm_id) == var.control_plane.vm_id &&
      can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.control_plane.name))
    )
    error_message = "control_plane requires a valid VM ID and hostname."
  }
}

variable "primary_vlan_id" {
  description = "Primary node/API access VLAN tag for server and workers; no untagged primary NIC."
  type        = number
  nullable    = false
  sensitive   = true
  validation {
    condition     = var.primary_vlan_id >= 1 && var.primary_vlan_id <= 4094 && floor(var.primary_vlan_id) == var.primary_vlan_id
    error_message = "primary_vlan_id must be an integer from 1 through 4094."
  }
}

variable "cloud_user" {
  description = "Non-root guest administrator."
  type        = string
  nullable    = false
  sensitive   = true
  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]*$", var.cloud_user)) && var.cloud_user != "root"
    error_message = "cloud_user must be a non-root Linux username."
  }
}

variable "cloud_ssh_public_keys" {
  description = "Reviewed operator SSH public keys, replacing the template's administrator key list."
  type        = set(string)
  nullable    = false
  sensitive   = true
  validation {
    condition     = length(var.cloud_ssh_public_keys) > 0 && alltrue([for key in var.cloud_ssh_public_keys : can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+={0,3}( [^\r\n]*)?$", key))])
    error_message = "cloud_ssh_public_keys must contain SSH public keys, never private keys."
  }
}

variable "technitium_server_url" {
  description = "Verified HTTPS DNS API endpoint; authentication uses TECHNITIUM_API_TOKEN."
  type        = string
  nullable    = false
  sensitive   = true
  validation {
    condition     = can(regex("^https://[^/]+", var.technitium_server_url))
    error_message = "technitium_server_url must be an HTTPS URL."
  }
}

variable "api_dns" {
  description = "Existing managed zone and stable private API FQDN; this root owns only its A record."
  type = object({
    zone = string
    name = string
    ttl  = optional(number, 300)
  })
  nullable  = false
  sensitive = true
  validation {
    condition = (
      length(var.api_dns.name) <= 253 && length(var.api_dns.zone) <= 253 &&
      alltrue([for label in concat(split(".", var.api_dns.zone), split(".", var.api_dns.name)) : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", label))]) &&
      endswith(var.api_dns.name, ".${var.api_dns.zone}") &&
      floor(var.api_dns.ttl) == var.api_dns.ttl && var.api_dns.ttl >= 30 && var.api_dns.ttl <= 86400
    )
    error_message = "api_dns requires a hostname within its zone and an integer TTL from 30 through 86400."
  }
}

variable "cluster_networks" {
  description = "Private internal IPv4 pod and Service CIDRs; separate from LAN pools."
  type = object({
    pods     = string
    services = string
  })
  nullable  = false
  sensitive = true
  validation {
    condition     = alltrue([for cidr in [var.cluster_networks.pods, var.cluster_networks.services] : try(can(cidrnetmask(cidr)) && cidrhost(cidr, 0) == split("/", cidr)[0], false)])
    error_message = "cluster_networks must contain canonical IPv4 network CIDRs without host bits."
  }
}

variable "control_plane_resources" {
  description = "Initial server allocation, independent of worker resources."
  type = object({
    cpu_cores    = optional(number, 2)
    memory_mb    = optional(number, 4096)
    disk_size_gb = optional(number, 32)
  })
  default  = {}
  nullable = false
  validation {
    condition     = var.control_plane_resources.cpu_cores >= 2 && floor(var.control_plane_resources.cpu_cores) == var.control_plane_resources.cpu_cores && var.control_plane_resources.memory_mb >= 4096 && floor(var.control_plane_resources.memory_mb) == var.control_plane_resources.memory_mb && var.control_plane_resources.disk_size_gb >= 32 && floor(var.control_plane_resources.disk_size_gb) == var.control_plane_resources.disk_size_gb
    error_message = "Server allocations must be whole numbers with at least 2 cores, 4096 MiB and 32 GiB."
  }
}

variable "rke2_version" {
  description = "Exact EL10 server/agent/common RPM version-release; changes require compatibility review."
  type        = string
  default     = "1.36.6~rke2r1-0.el10"
  nullable    = false
  validation {
    condition     = can(regex("^1\\.[0-9]+\\.[0-9]+~rke2r[0-9]+-[0-9]+\\.el10$", var.rke2_version))
    error_message = "rke2_version must pin an exact RKE2 EL10 version-release."
  }
}

variable "rke2_selinux_version" {
  description = "Exact EL10 RKE2 SELinux RPM version-release."
  type        = string
  default     = "0.24-1.el10"
  nullable    = false
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+-[0-9]+\\.el10$", var.rke2_selinux_version))
    error_message = "rke2_selinux_version must pin an exact EL10 version-release."
  }
}

variable "workers" {
  description = "Worker short names, OS FQDNs and secondary bridges keyed by physical host; empty disables provisioning. Proxmox owns both NIC MACs."
  type = map(object({
    vm_id          = number
    name           = string
    fqdn           = string
    service_bridge = string
  }))
  default   = {}
  nullable  = false
  sensitive = true
  validation {
    condition = length(var.workers) == 0 || (
      toset(keys(var.workers)) == toset(["compute", "store"]) &&
      length(distinct([for worker in values(var.workers) : worker.vm_id])) == 2 &&
      length(distinct([for worker in values(var.workers) : worker.name])) == 2 &&
      alltrue([for host, worker in var.workers :
        contains(keys(var.proxmox_nodes), host) &&
        worker.vm_id >= 100 && worker.vm_id <= 999999999 && floor(worker.vm_id) == worker.vm_id &&
        worker.vm_id != var.template.vm_id && worker.vm_id != var.control_plane.vm_id &&
        worker.name != var.control_plane.name &&
        can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", worker.name)) &&
        can(regex("^[A-Za-z0-9_.-]+$", worker.service_bridge))
      ])
    )
    error_message = "Enable exactly one uniquely identified worker on compute and store, with existing host inputs, valid secondary bridges and no server/template identity collision."
  }
  validation {
    condition = alltrue([for worker in values(var.workers) :
      can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$", worker.fqdn)) &&
      try(length(worker.fqdn) <= 253 && split(".", worker.fqdn)[0] == worker.name, false)
    ])
    error_message = "Each worker requires a lowercase DNS FQDN of at most 253 characters, without a trailing dot, whose first label matches its short name."
  }
}

variable "service_vlan_id" {
  description = "Secondary worker service-network access tag; null only when workers are disabled."
  type        = number
  default     = null
  sensitive   = true
  validation {
    condition = var.service_vlan_id == null ? length(var.workers) == 0 : (
      var.service_vlan_id >= 1 && var.service_vlan_id <= 4094 &&
      floor(var.service_vlan_id) == var.service_vlan_id && var.service_vlan_id != var.primary_vlan_id
    )
    error_message = "Enabled workers require a service VLAN tag distinct from the primary tag, from 1 through 4094."
  }
}

variable "worker_resources" {
  description = "Per-worker allocation, independent of the server."
  type = object({
    cpu_cores    = optional(number, 4)
    memory_mb    = optional(number, 8192)
    disk_size_gb = optional(number, 64)
  })
  default  = {}
  nullable = false
  validation {
    condition = alltrue([
      var.worker_resources.cpu_cores >= 4 && floor(var.worker_resources.cpu_cores) == var.worker_resources.cpu_cores,
      var.worker_resources.memory_mb >= 8192 && floor(var.worker_resources.memory_mb) == var.worker_resources.memory_mb,
      var.worker_resources.disk_size_gb >= 64 && floor(var.worker_resources.disk_size_gb) == var.worker_resources.disk_size_gb,
    ])
    error_message = "Workers require whole-number allocations of at least 4 cores, 8192 MiB and 64 GiB."
  }
}
