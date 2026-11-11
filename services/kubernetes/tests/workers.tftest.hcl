mock_provider "proxmox" {
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "snippets:snippets/fixture.yaml" }
  }
}
mock_provider "technitium" {}

variables {
  proxmox_endpoint     = "https://proxmox.example.invalid"
  proxmox_ssh_username = "testadmin"
  proxmox_nodes = {
    compute = { ssh_address = "compute.example.invalid", snippet_datastore_id = "snippets", vm_datastore_id = "vms", vm_bridge = "br-primary" }
    store   = { ssh_address = "store.example.invalid", snippet_datastore_id = "snippets", vm_datastore_id = "vms", vm_bridge = "br-primary" }
  }
  template              = { vm_id = 100, node_name = "compute" }
  control_plane         = { vm_id = 101, name = "test-server" }
  primary_vlan_id       = 100
  service_vlan_id       = 200
  cloud_user            = "testadmin"
  cloud_ssh_public_keys = ["ssh-ed25519 c3ludGhldGljLWtleQ== test-fixture"]
  technitium_server_url = "https://dns.example.invalid"
  api_dns               = { zone = "example.invalid", name = "api.example.invalid" }
  cluster_networks      = { pods = "198.18.0.0/16", services = "198.19.0.0/16" }
  workers = {
    compute = { vm_id = 102, name = "test-worker-a", service_bridge = "br-service" }
    store   = { vm_id = 103, name = "test-worker-b", service_bridge = "br-service" }
  }
}

run "declare_workers_without_changing_server_or_supplying_credentials" {
  command = plan
  assert {
    condition = nonsensitive(alltrue([
      for host, vm in proxmox_virtual_environment_vm.worker :
      vm.node_name == host && vm.protection && vm.on_boot && !vm.migrate &&
      vm.cpu[0].type == "host" && vm.cpu[0].cores == 4 &&
      vm.memory[0].dedicated == 8192 && vm.disk[0].size == 64 &&
      vm.clone[0].full && vm.clone[0].node_name == "compute" &&
      length(vm.network_device) == 2 &&
      vm.network_device[0].vlan_id == 100 && vm.network_device[1].vlan_id == 200 &&
      length(vm.initialization[0].ip_config) == 0 &&
      yamldecode(local.worker_rke2_config[host])["token-file"] == "/etc/rancher/rke2/join-token" &&
      !contains(keys(yamldecode(local.worker_rke2_config[host])), "token") &&
      !contains(keys(yamldecode(local.worker_rke2_config[host])), "node-ip") &&
      yamldecode(local.worker_rke2_config[host]).server == "https://api.example.invalid:9345" &&
      strcontains(local.worker_cloud_init[host], "ConditionPathExists=/etc/rancher/rke2/join-token") &&
      base64decode(yamldecode(local.worker_cloud_init[host]).write_files[0].content) == file("${path.module}/cloud-init/install-agent.sh") &&
      base64decode(yamldecode(local.worker_cloud_init[host]).write_files[2].content) == local.worker_rke2_config[host] &&
      yamldecode(local.worker_cloud_init[host]).power_state.condition == ["test", "-f", "/var/lib/kubernetes-agent-installed"] &&
      !strcontains(local.worker_cloud_init[host], "BEGIN PRIVATE KEY")
    ]))
    error_message = "Workers must remain protected, host-local, dual-NIC and gated on out-of-band credential enrollment."
  }
  assert {
    condition = (
      yamldecode(file("${path.module}/cloud-init/worker-network-data.yaml")).ethernets.ens18.dhcp4 &&
      !contains(keys(yamldecode(file("${path.module}/cloud-init/worker-network-data.yaml")).ethernets), "ens19") &&
      strcontains(file("${path.module}/config/worker-service.nmconnection"), "never-default=true") &&
      strcontains(file("${path.module}/config/worker-service.nmconnection"), "ignore-auto-dns=true") &&
      strcontains(file("${path.module}/config/worker-service.nmconnection"), "ignore-auto-routes=true")
    )
    error_message = "Only the primary interface may accept DHCP routes and DNS."
  }
  expect_failures = [technitium_record.api]
}

run "require_service_vlan_when_workers_enabled" {
  command = plan
  variables { service_vlan_id = null }
  expect_failures = [var.service_vlan_id, technitium_record.api]
}

run "preserve_server_only_configuration_when_workers_disabled" {
  command = plan
  variables { workers = {} }
  assert {
    condition     = length(proxmox_virtual_environment_vm.worker) == 0
    error_message = "Omitting workers must preserve the established server-only deployment."
  }
  expect_failures = [technitium_record.api]
}

run "reject_worker_identity_collision" {
  command = plan
  variables {
    workers = {
      compute = { vm_id = 101, name = "test-server", service_bridge = "br-service" }
      store   = { vm_id = 103, name = "test-worker-b", service_bridge = "br-service" }
    }
  }
  expect_failures = [var.workers, technitium_record.api]
}

run "reject_same_service_and_primary_vlan" {
  command = plan
  variables { service_vlan_id = 100 }
  expect_failures = [var.service_vlan_id, technitium_record.api]
}
