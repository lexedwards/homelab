mock_provider "proxmox" {}
mock_provider "technitium" {}

variables {
  proxmox_endpoint             = "https://proxmox.example.invalid"
  proxmox_api_token            = "synthetic-test-token"
  proxmox_ssh_username         = "test@pam"
  proxmox_ssh_private_key_file = "tests/s3-tls.tftest.hcl"
  proxmox_nodes = {
    compute = { ssh_address = "compute.example.invalid", snippet_datastore_id = "snippets", vm_datastore_id = "vms", vm_bridge = "br0" }
    store   = { ssh_address = "store.example.invalid", snippet_datastore_id = "snippets", vm_datastore_id = "vms", vm_bridge = "br0" }
  }
  warehouse_vm_id       = 100
  collector_vm_id       = 101
  grafana_vm_id         = 102
  template_vm_id        = 103
  template_node_name    = "store"
  cloud_user            = "test"
  cloud_ssh_public_keys = ["synthetic-test-key"]
  nfs_server            = "backup.example.invalid"
  nfs_export            = "/backups"
  s3_endpoint           = "storage.example.invalid:9000"
  technitium_server_url = "https://dns.example.invalid"
  technitium_records    = {}
}

run "default_configs_require_https_and_certificate_verification" {
  command = plan
  plan_options { target = [proxmox_virtual_environment_file.cloud_init] }

  assert {
    condition = alltrue([for config in yamldecode(proxmox_virtual_environment_file.cloud_init.source_raw[0].data).write_files : (
      !yamldecode(base64decode(config.content)).common.storage.s3.insecure &&
      !yamldecode(base64decode(config.content)).common.storage.s3.http.insecure_skip_verify
    ) if config.path == "/etc/observability-warehouse/mimir.yaml"])
    error_message = "The deployed Mimir configuration must use verified HTTPS by default."
  }
  assert {
    condition = alltrue([for config in yamldecode(proxmox_virtual_environment_file.cloud_init.source_raw[0].data).write_files : (
      !yamldecode(base64decode(config.content)).storage_config.aws.insecure &&
      !yamldecode(base64decode(config.content)).storage_config.aws.http_config.insecure_skip_verify
    ) if config.path == "/etc/observability-warehouse/loki.yaml"])
    error_message = "The deployed Loki configuration must use verified HTTPS by default."
  }
  assert {
    condition = alltrue([for config in yamldecode(proxmox_virtual_environment_file.cloud_init.source_raw[0].data).write_files : (
      !yamldecode(base64decode(config.content)).storage.trace.s3.insecure &&
      !yamldecode(base64decode(config.content)).storage.trace.s3.tls_insecure_skip_verify
    ) if config.path == "/etc/observability-warehouse/tempo.yaml"])
    error_message = "The deployed Tempo configuration must use verified HTTPS by default."
  }
  assert {
    condition = sort([for config in yamldecode(proxmox_virtual_environment_file.cloud_init.source_raw[0].data).write_files : config.path
      if contains(["/etc/observability-warehouse/mimir.yaml", "/etc/observability-warehouse/loki.yaml", "/etc/observability-warehouse/tempo.yaml"], config.path)
    ]) == sort(["/etc/observability-warehouse/mimir.yaml", "/etc/observability-warehouse/loki.yaml", "/etc/observability-warehouse/tempo.yaml"])
    error_message = "Each of the three rendered S3 client configurations must be present exactly once."
  }
}
