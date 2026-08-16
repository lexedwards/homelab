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

variable "proxmox_nodes" {
  description = "Proxmox nodes available to this service, keyed by node name."
  type = map(object({
    ssh_address          = string
    snippet_datastore_id = string
    vm_datastore_id      = string
    vm_bridge            = string
  }))
  nullable = false

  validation {
    condition = (
      length(var.proxmox_nodes) > 0 &&
      alltrue([
        for name, node in var.proxmox_nodes :
        can(regex("^[A-Za-z0-9_.-]+$", name)) &&
        can(regex("^[A-Za-z0-9.-]+$", node.ssh_address)) &&
        length(trimspace(node.snippet_datastore_id)) > 0 &&
        length(trimspace(node.vm_datastore_id)) > 0 &&
        length(trimspace(node.vm_bridge)) > 0
      ])
    )
    error_message = "proxmox_nodes must define at least one valid node name, SSH address, snippet datastore, VM datastore, and bridge."
  }
}

variable "warehouse_node_name" {
  description = "Name of the Proxmox VE node that hosts the warehouse VM."
  type        = string
  default     = "store"
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+$", var.warehouse_node_name))
    error_message = "warehouse_node_name must be a valid Proxmox node name."
  }
}

variable "warehouse_vm_id" {
  description = "Unique Proxmox VM ID for the warehouse."
  type        = number
  nullable    = false

  validation {
    condition     = var.warehouse_vm_id >= 100 && var.warehouse_vm_id <= 999999999 && floor(var.warehouse_vm_id) == var.warehouse_vm_id
    error_message = "warehouse_vm_id must be a whole number from 100 through 999999999."
  }
}

variable "template_vm_id" {
  description = "VM ID of the Debian 13 cloud-image template to clone."
  type        = number
  nullable    = false

  validation {
    condition     = var.template_vm_id >= 100 && var.template_vm_id <= 999999999 && floor(var.template_vm_id) == var.template_vm_id
    error_message = "template_vm_id must be a whole number from 100 through 999999999."
  }
}

variable "template_node_name" {
  description = "Proxmox VE node that hosts the Debian 13 source VM template."
  type        = string
  nullable    = false

  validation {
    condition     = length(trimspace(var.template_node_name)) > 0
    error_message = "template_node_name must not be empty."
  }
}

variable "vm_vlan_id" {
  description = "Optional VLAN tag attached to every service VM network device."
  type        = number
  default     = null

  validation {
    condition     = var.vm_vlan_id == null || (var.vm_vlan_id >= 1 && var.vm_vlan_id <= 4094 && floor(var.vm_vlan_id) == var.vm_vlan_id)
    error_message = "vm_vlan_id must be null or an integer from 1 through 4094."
  }
}

variable "cloud_user" {
  description = "Administrative user created in every service VM."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]*$", var.cloud_user))
    error_message = "cloud_user must be a valid lowercase Linux username."
  }
}

variable "cloud_ssh_public_keys" {
  description = "SSH public keys authorized for the service administrative user."
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

variable "warehouse_vm_cpu_cores" {
  description = "Number of CPU cores assigned to the warehouse VM."
  type        = number
  default     = 8
  nullable    = false

  validation {
    condition     = var.warehouse_vm_cpu_cores >= 2 && var.warehouse_vm_cpu_cores <= 128 && floor(var.warehouse_vm_cpu_cores) == var.warehouse_vm_cpu_cores
    error_message = "warehouse_vm_cpu_cores must be a whole number from 2 through 128."
  }
}

variable "warehouse_vm_memory_mb" {
  description = "Dedicated memory assigned to the warehouse VM in MiB."
  type        = number
  default     = 16384
  nullable    = false

  validation {
    condition     = var.warehouse_vm_memory_mb >= 4096 && floor(var.warehouse_vm_memory_mb) == var.warehouse_vm_memory_mb
    error_message = "warehouse_vm_memory_mb must be a whole number of at least 4096."
  }
}

variable "warehouse_vm_disk_size_gb" {
  description = "Size of the warehouse VM system and working-data disk in GiB."
  type        = number
  default     = 128
  nullable    = false

  validation {
    condition     = var.warehouse_vm_disk_size_gb >= 32 && floor(var.warehouse_vm_disk_size_gb) == var.warehouse_vm_disk_size_gb
    error_message = "warehouse_vm_disk_size_gb must be a whole number of at least 32."
  }
}

variable "nfs_server" {
  description = "Hostname or address of the NFS server used as the backup destination."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9.-]+$", var.nfs_server))
    error_message = "nfs_server must be a hostname or IPv4 address without a port."
  }
}

variable "nfs_export" {
  description = "Absolute NFS export path mounted at /mnt/warehouse."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^/[A-Za-z0-9._/-]+$", var.nfs_export))
    error_message = "nfs_export must be an absolute path containing only letters, numbers, dots, underscores, hyphens, and slashes."
  }
}

variable "nfs_mount_options" {
  description = "Mount options for the warehouse NFS backup destination."
  type        = string
  default     = "rw,_netdev,nofail,x-systemd.automount,x-systemd.device-timeout=10s"
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9=.,_-]+$", var.nfs_mount_options))
    error_message = "nfs_mount_options must be a non-empty comma-separated mount option list."
  }
}

variable "s3_endpoint" {
  description = "RustFS S3 endpoint in host:port form, without a URL scheme."
  type        = string
  nullable    = false

  validation {
    condition = (
      can(regex("^[A-Za-z0-9.-]+:[0-9]+$", var.s3_endpoint)) &&
      try(tonumber(element(split(":", var.s3_endpoint), 1)) >= 1, false) &&
      try(tonumber(element(split(":", var.s3_endpoint), 1)) <= 65535, false)
    )
    error_message = "s3_endpoint must use host:port form without a URL scheme and with a valid TCP port."
  }
}

variable "s3_access_key_id" {
  description = "RustFS S3 access key ID shared by Mimir, Loki, and Tempo."
  type        = string
  default     = ""
  nullable    = false
  sensitive   = true

  validation {
    condition     = var.s3_access_key_id == "" || (length(trimspace(var.s3_access_key_id)) > 0 && !strcontains(var.s3_access_key_id, "\n"))
    error_message = "s3_access_key_id must be empty or a non-empty single-line value."
  }
}

variable "s3_secret_access_key" {
  description = "RustFS S3 secret access key shared by Mimir, Loki, and Tempo."
  type        = string
  default     = ""
  nullable    = false
  sensitive   = true

  validation {
    condition     = var.s3_secret_access_key == "" || (length(trimspace(var.s3_secret_access_key)) > 0 && !strcontains(var.s3_secret_access_key, "\n"))
    error_message = "s3_secret_access_key must be empty or a non-empty single-line value."
  }
}

variable "s3_insecure" {
  description = "Use plaintext HTTP instead of HTTPS when connecting to RustFS."
  type        = bool
  default     = false
  nullable    = false
}

variable "s3_insecure_skip_verify" {
  description = "Skip verification of the RustFS HTTPS certificate."
  type        = bool
  default     = true
  nullable    = false
}

variable "mimir_bucket_name" {
  description = "Existing RustFS bucket used by Mimir."
  type        = string
  default     = "mimir"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.mimir_bucket_name))
    error_message = "mimir_bucket_name must be a valid S3 bucket name."
  }
}

variable "loki_bucket_name" {
  description = "Existing RustFS bucket used by Loki."
  type        = string
  default     = "loki"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.loki_bucket_name))
    error_message = "loki_bucket_name must be a valid S3 bucket name."
  }
}

variable "tempo_bucket_name" {
  description = "Existing RustFS bucket used by Tempo."
  type        = string
  default     = "tempo"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.tempo_bucket_name))
    error_message = "tempo_bucket_name must be a valid S3 bucket name."
  }
}

variable "retention_hours" {
  description = "Retention period shared by Mimir, Loki, and Tempo, in hours."
  type        = number
  default     = 720
  nullable    = false

  validation {
    condition     = var.retention_hours >= 24 && floor(var.retention_hours) == var.retention_hours
    error_message = "retention_hours must be a whole number of at least 24."
  }
}

variable "collector_node_name" {
  description = "Name of the Proxmox VE node that hosts the collector VM."
  type        = string
  default     = "compute"
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+$", var.collector_node_name))
    error_message = "collector_node_name must be a valid Proxmox node name."
  }
}

variable "collector_vm_id" {
  description = "Cluster-wide Proxmox VM ID for the collector."
  type        = number
  nullable    = false

  validation {
    condition     = var.collector_vm_id >= 100 && var.collector_vm_id <= 999999999 && floor(var.collector_vm_id) == var.collector_vm_id
    error_message = "collector_vm_id must be a whole number from 100 through 999999999."
  }
}

variable "collector_vm_cpu_cores" {
  description = "Number of CPU cores assigned to the collector VM."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.collector_vm_cpu_cores >= 1 && var.collector_vm_cpu_cores <= 32 && floor(var.collector_vm_cpu_cores) == var.collector_vm_cpu_cores
    error_message = "collector_vm_cpu_cores must be a whole number from 1 through 32."
  }
}

variable "collector_vm_memory_mb" {
  description = "Dedicated memory assigned to the collector VM in MiB."
  type        = number
  default     = 2048
  nullable    = false

  validation {
    condition     = var.collector_vm_memory_mb >= 1024 && floor(var.collector_vm_memory_mb) == var.collector_vm_memory_mb
    error_message = "collector_vm_memory_mb must be a whole number of at least 1024."
  }
}

variable "collector_vm_disk_size_gb" {
  description = "Size of the collector VM system and telemetry-buffer disk in GiB."
  type        = number
  default     = 32
  nullable    = false

  validation {
    condition     = var.collector_vm_disk_size_gb >= 16 && floor(var.collector_vm_disk_size_gb) == var.collector_vm_disk_size_gb
    error_message = "collector_vm_disk_size_gb must be a whole number of at least 16."
  }
}

variable "alloy_version" {
  description = "Exact Grafana Alloy package version installed from the Grafana repository."
  type        = string
  default     = "1.18.1-1"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+$", var.alloy_version))
    error_message = "alloy_version must be an exact package version such as 1.18.1-1."
  }
}

variable "grafana_node_name" {
  description = "Name of the Proxmox VE node that hosts the Grafana VM."
  type        = string
  default     = "compute"
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+$", var.grafana_node_name))
    error_message = "grafana_node_name must be a valid Proxmox node name."
  }
}

variable "grafana_vm_id" {
  description = "Cluster-wide Proxmox VM ID for Grafana."
  type        = number
  nullable    = false

  validation {
    condition     = var.grafana_vm_id >= 100 && var.grafana_vm_id <= 999999999 && floor(var.grafana_vm_id) == var.grafana_vm_id
    error_message = "grafana_vm_id must be a whole number from 100 through 999999999."
  }
}

variable "grafana_vm_cpu_cores" {
  description = "Number of CPU cores assigned to the Grafana VM."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.grafana_vm_cpu_cores >= 1 && var.grafana_vm_cpu_cores <= 32 && floor(var.grafana_vm_cpu_cores) == var.grafana_vm_cpu_cores
    error_message = "grafana_vm_cpu_cores must be a whole number from 1 through 32."
  }
}

variable "grafana_vm_memory_mb" {
  description = "Dedicated memory assigned to the Grafana VM in MiB."
  type        = number
  default     = 4096
  nullable    = false

  validation {
    condition     = var.grafana_vm_memory_mb >= 1024 && floor(var.grafana_vm_memory_mb) == var.grafana_vm_memory_mb
    error_message = "grafana_vm_memory_mb must be a whole number of at least 1024."
  }
}

variable "grafana_vm_disk_size_gb" {
  description = "Size of the Grafana VM system and application-data disk in GiB."
  type        = number
  default     = 32
  nullable    = false

  validation {
    condition     = var.grafana_vm_disk_size_gb >= 16 && floor(var.grafana_vm_disk_size_gb) == var.grafana_vm_disk_size_gb
    error_message = "grafana_vm_disk_size_gb must be a whole number of at least 16."
  }
}

variable "grafana_version" {
  description = "Exact Grafana OSS package version installed from the Grafana repository."
  type        = string
  default     = "13.1.1"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9]+)?$", var.grafana_version))
    error_message = "grafana_version must be an exact package version such as 13.1.1."
  }
}
