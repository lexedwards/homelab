provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  ssh {
    agent       = true
    username    = var.proxmox_ssh_username
    private_key = file(pathexpand(var.proxmox_ssh_private_key_file))

    dynamic "node" {
      for_each = var.proxmox_nodes

      content {
        name    = node.key
        address = node.value.ssh_address
      }
    }
  }
}

locals {
  host_config = var.proxmox_nodes

  service_config = {
    s3_endpoint             = jsonencode(var.s3_endpoint)
    s3_insecure             = var.s3_insecure
    s3_insecure_skip_verify = var.s3_insecure_skip_verify
    mimir_bucket            = jsonencode(var.mimir_bucket_name)
    loki_bucket             = jsonencode(var.loki_bucket_name)
    tempo_bucket            = jsonencode(var.tempo_bucket_name)
    retention_period        = "${var.retention_hours}h"
  }

  s3_credentials_configured  = var.s3_access_key_id != "" && var.s3_secret_access_key != ""
  object_storage_environment = <<-EOT
    AWS_ACCESS_KEY_ID=${jsonencode(var.s3_access_key_id)}
    AWS_SECRET_ACCESS_KEY=${jsonencode(var.s3_secret_access_key)}
  EOT

  cloud_init_user_data = templatefile("${path.module}/cloud-init/user-data.tftpl", {
    cloud_user                        = var.cloud_user
    cloud_ssh_public_keys             = jsonencode(sort(tolist(var.cloud_ssh_public_keys)))
    nfs_source                        = "${var.nfs_server}:${var.nfs_export}"
    nfs_mount_options                 = var.nfs_mount_options
    compose_config_base64             = base64encode(file("${path.module}/config/compose.yaml"))
    mimir_config_base64               = base64encode(templatefile("${path.module}/config/mimir.yaml.tftpl", local.service_config))
    loki_config_base64                = base64encode(templatefile("${path.module}/config/loki.yaml.tftpl", local.service_config))
    tempo_config_base64               = base64encode(templatefile("${path.module}/config/tempo.yaml.tftpl", local.service_config))
    s3_credentials_configured         = local.s3_credentials_configured
    object_storage_environment_base64 = base64encode(local.object_storage_environment)
  })

  warehouse_network_interface_index = index(
    [for address in proxmox_virtual_environment_vm.observability_warehouse.mac_addresses : lower(address)],
    lower(proxmox_virtual_environment_vm.observability_warehouse.network_device[0].mac_address),
  )
  warehouse_ipv4_address = one([
    for address in proxmox_virtual_environment_vm.observability_warehouse.ipv4_addresses[local.warehouse_network_interface_index] : address
    if address != "127.0.0.1" && !startswith(address, "169.254.")
  ])

  collector_alloy_environment = templatefile("${path.module}/config/alloy.env.tftpl", {
    warehouse_host = local.warehouse_ipv4_address
  })

  collector_cloud_init_user_data = templatefile("${path.module}/cloud-init/collector-user-data.tftpl", {
    alloy_config_base64      = base64encode(file("${path.module}/config/config.alloy"))
    alloy_environment_base64 = base64encode(local.collector_alloy_environment)
    alloy_environment_path   = "/etc/default/alloy"
    alloy_installer_base64   = base64encode(file("${path.module}/cloud-init/install-alloy-debian.sh"))
    alloy_version            = var.alloy_version
    cloud_user               = var.cloud_user
    cloud_ssh_public_keys    = jsonencode(sort(tolist(var.cloud_ssh_public_keys)))
  })

  grafana_datasources_config = templatefile("${path.module}/config/grafana-datasources.yaml.tftpl", {
    warehouse_host = local.warehouse_ipv4_address
  })

  grafana_cloud_init_user_data = templatefile("${path.module}/cloud-init/grafana-user-data.tftpl", {
    cloud_user                 = var.cloud_user
    cloud_ssh_public_keys      = jsonencode(sort(tolist(var.cloud_ssh_public_keys)))
    grafana_datasources_base64 = base64encode(local.grafana_datasources_config)
    grafana_installer_base64   = base64encode(file("${path.module}/cloud-init/install-grafana-debian.sh"))
    grafana_version            = var.grafana_version
  })
}

check "node_placements" {
  assert {
    condition = alltrue([
      for node_name in [var.warehouse_node_name, var.collector_node_name, var.grafana_node_name] :
      contains(keys(var.proxmox_nodes), node_name)
    ])
    error_message = "warehouse_node_name, collector_node_name, and grafana_node_name must each identify a key in proxmox_nodes."
  }
}

resource "proxmox_virtual_environment_file" "cloud_init" {
  content_type = "snippets"
  datastore_id = local.host_config[var.warehouse_node_name].snippet_datastore_id
  node_name    = var.warehouse_node_name

  source_raw {
    data      = local.cloud_init_user_data
    file_name = "observability-warehouse_cloud-config.yaml"
  }

  lifecycle {
    precondition {
      condition = (
        (var.s3_access_key_id == "" && var.s3_secret_access_key == "") ||
        (var.s3_access_key_id != "" && var.s3_secret_access_key != "")
      )
      error_message = "s3_access_key_id and s3_secret_access_key must either both be set or both be empty."
    }
  }
}

resource "proxmox_virtual_environment_vm" "observability_warehouse" {
  name        = "observability-warehouse"
  description = "Mimir, Loki, and Tempo observability storage managed by OpenTofu."
  tags        = ["iac", "observability", "warehouse"]
  node_name   = var.warehouse_node_name
  vm_id       = var.warehouse_vm_id

  started    = true
  on_boot    = true
  protection = true

  clone {
    vm_id        = var.template_vm_id
    node_name    = var.template_node_name
    datastore_id = local.host_config[var.warehouse_node_name].vm_datastore_id
    full         = true
    retries      = 3
  }

  agent {
    enabled = true
    trim    = true

    wait_for_ip {
      ipv4 = true
    }
  }

  cpu {
    cores = var.warehouse_vm_cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.warehouse_vm_memory_mb
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = local.host_config[var.warehouse_node_name].vm_datastore_id
    interface    = "scsi0"
    discard      = "on"
    iothread     = true
    size         = var.warehouse_vm_disk_size_gb
    ssd          = true
  }

  initialization {
    datastore_id      = local.host_config[var.warehouse_node_name].vm_datastore_id
    user_data_file_id = proxmox_virtual_environment_file.cloud_init.id

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  network_device {
    bridge  = local.host_config[var.warehouse_node_name].vm_bridge
    model   = "virtio"
    vlan_id = var.vm_vlan_id
  }

  operating_system {
    type = "l26"
  }

  startup {
    order      = "3"
    up_delay   = "30"
    down_delay = "120"
  }

  lifecycle {
    precondition {
      condition     = var.warehouse_vm_id != var.template_vm_id
      error_message = "warehouse_vm_id and template_vm_id must be different cluster-wide VM IDs."
    }
  }
}

resource "proxmox_virtual_environment_file" "collector_cloud_init" {
  content_type = "snippets"
  datastore_id = local.host_config[var.collector_node_name].snippet_datastore_id
  node_name    = var.collector_node_name

  source_raw {
    data      = local.collector_cloud_init_user_data
    file_name = "telemetry-collector_cloud-config.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "telemetry_collector" {
  name        = "telemetry-collector"
  description = "Grafana Alloy telemetry gateway managed by OpenTofu."
  tags        = ["alloy", "iac", "observability", "telemetry"]
  node_name   = var.collector_node_name
  vm_id       = var.collector_vm_id

  started    = true
  on_boot    = true
  protection = true

  clone {
    vm_id        = var.template_vm_id
    node_name    = var.template_node_name
    datastore_id = local.host_config[var.collector_node_name].vm_datastore_id
    full         = true
    retries      = 3
  }

  agent {
    enabled = true
    trim    = true

    wait_for_ip {
      ipv4 = true
    }
  }

  cpu {
    cores = var.collector_vm_cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.collector_vm_memory_mb
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = local.host_config[var.collector_node_name].vm_datastore_id
    interface    = "scsi0"
    discard      = "on"
    iothread     = true
    size         = var.collector_vm_disk_size_gb
    ssd          = true
  }

  initialization {
    datastore_id      = local.host_config[var.collector_node_name].vm_datastore_id
    user_data_file_id = proxmox_virtual_environment_file.collector_cloud_init.id

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  network_device {
    bridge  = local.host_config[var.collector_node_name].vm_bridge
    model   = "virtio"
    vlan_id = var.vm_vlan_id
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    precondition {
      condition     = !contains([var.warehouse_vm_id, var.template_vm_id], var.collector_vm_id)
      error_message = "collector_vm_id must differ from warehouse_vm_id and template_vm_id."
    }
  }
}

resource "proxmox_virtual_environment_file" "grafana_cloud_init" {
  content_type = "snippets"
  datastore_id = local.host_config[var.grafana_node_name].snippet_datastore_id
  node_name    = var.grafana_node_name

  source_raw {
    data      = local.grafana_cloud_init_user_data
    file_name = "grafana_cloud-config.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "grafana" {
  name        = "grafana"
  description = "Grafana dashboards and visualization managed by OpenTofu."
  tags        = ["grafana", "iac", "observability"]
  node_name   = var.grafana_node_name
  vm_id       = var.grafana_vm_id

  started    = true
  on_boot    = true
  protection = true

  clone {
    vm_id        = var.template_vm_id
    node_name    = var.template_node_name
    datastore_id = local.host_config[var.grafana_node_name].vm_datastore_id
    full         = true
    retries      = 3
  }

  agent {
    enabled = true
    trim    = true

    wait_for_ip {
      ipv4 = true
    }
  }

  cpu {
    cores = var.grafana_vm_cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.grafana_vm_memory_mb
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = local.host_config[var.grafana_node_name].vm_datastore_id
    interface    = "scsi0"
    discard      = "on"
    iothread     = true
    size         = var.grafana_vm_disk_size_gb
    ssd          = true
  }

  initialization {
    datastore_id      = local.host_config[var.grafana_node_name].vm_datastore_id
    user_data_file_id = proxmox_virtual_environment_file.grafana_cloud_init.id

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  network_device {
    bridge  = local.host_config[var.grafana_node_name].vm_bridge
    model   = "virtio"
    vlan_id = var.vm_vlan_id
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    precondition {
      condition     = !contains([var.warehouse_vm_id, var.collector_vm_id, var.template_vm_id], var.grafana_vm_id)
      error_message = "grafana_vm_id must differ from warehouse_vm_id, collector_vm_id, and template_vm_id."
    }
  }
}

output "warehouse_ipv4_addresses" {
  description = "IPv4 addresses reported by the QEMU guest agent for the warehouse VM."
  sensitive   = true
  value       = proxmox_virtual_environment_vm.observability_warehouse.ipv4_addresses
}

output "collector_ipv4_addresses" {
  description = "IPv4 addresses reported by the QEMU guest agent for the telemetry collector VM."
  sensitive   = true
  value       = proxmox_virtual_environment_vm.telemetry_collector.ipv4_addresses
}

output "grafana_ipv4_addresses" {
  description = "IPv4 addresses reported by the QEMU guest agent for the Grafana VM."
  sensitive   = true
  value       = proxmox_virtual_environment_vm.grafana.ipv4_addresses
}
