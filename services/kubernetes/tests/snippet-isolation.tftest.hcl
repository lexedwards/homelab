mock_provider "proxmox" {}
mock_provider "technitium" {}

variables {
  proxmox_endpoint      = "https://proxmox.example.invalid"
  proxmox_ssh_username  = "operator"
  technitium_server_url = "https://dns.example.invalid"
  proxmox_nodes = {
    compute = {
      ssh_address          = "compute.example.invalid"
      snippet_datastore_id = "test-snippets"
      vm_datastore_id      = "test-disks"
      vm_bridge            = "test-bridge"
    }
    store = {
      ssh_address          = "store.example.invalid"
      snippet_datastore_id = "test-snippets"
      vm_datastore_id      = "test-disks"
      vm_bridge            = "test-bridge"
    }
  }
  template              = { vm_id = 900, node_name = "compute" }
  control_plane         = { vm_id = 901, name = "test-control-plane" }
  primary_vlan_id       = 100
  cloud_user            = "operator"
  cloud_ssh_public_keys = ["ssh-ed25519 dGVzdA=="]
  api_dns               = { zone = "example.invalid", name = "api.example.invalid" }
  cluster_networks      = { pods = "198.18.0.0/16", services = "198.19.0.0/16" }
  service_vlan_id       = 101
  workers = {
    compute = { vm_id = 902, name = "test-worker-a", fqdn = "test-worker-a.example.invalid", service_bridge = "test-services" }
    store   = { vm_id = 903, name = "test-worker-b", fqdn = "test-worker-b.example.invalid", service_bridge = "test-services" }
  }
}

run "default_snippet_paths" {
  command = plan
  plan_options {
    target = [proxmox_virtual_environment_file.control_plane, proxmox_virtual_environment_file.control_plane_network,
    proxmox_virtual_environment_file.worker, proxmox_virtual_environment_file.worker_network]
  }
  assert {
    condition = alltrue([
      proxmox_virtual_environment_file.control_plane.source_raw[0].file_name == "kubernetes-control-plane-cloud-config.yaml",
      proxmox_virtual_environment_file.control_plane_network.source_raw[0].file_name == "kubernetes-control-plane-network-config.yaml",
      alltrue([for file in proxmox_virtual_environment_file.worker : file.source_raw[0].file_name == "kubernetes-worker-cloud-config.yaml"]),
      alltrue([for file in proxmox_virtual_environment_file.worker_network : file.source_raw[0].file_name == "kubernetes-worker-network-config.yaml"]),
    ])
    error_message = "Default remote snippet paths must remain compatible with existing deployments."
  }
}

run "namespace_all_snippet_paths" {
  command = plan
  plan_options {
    target = [proxmox_virtual_environment_file.control_plane, proxmox_virtual_environment_file.control_plane_network,
    proxmox_virtual_environment_file.worker, proxmox_virtual_environment_file.worker_network]
  }
  variables { snippet_namespace = "test-isolated" }
  assert {
    condition = alltrue([
      proxmox_virtual_environment_file.control_plane.source_raw[0].file_name == "test-isolated-kubernetes-control-plane-cloud-config.yaml",
      proxmox_virtual_environment_file.control_plane_network.source_raw[0].file_name == "test-isolated-kubernetes-control-plane-network-config.yaml",
      alltrue([for file in proxmox_virtual_environment_file.worker : file.source_raw[0].file_name == "test-isolated-kubernetes-worker-cloud-config.yaml"]),
      alltrue([for file in proxmox_virtual_environment_file.worker_network : file.source_raw[0].file_name == "test-isolated-kubernetes-worker-network-config.yaml"]),
    ])
    error_message = "The namespace must isolate server and worker user-data and network-data filenames on every host."
  }
}
