mock_provider "proxmox" {
  mock_resource "proxmox_virtual_environment_file" {
    defaults = {
      id = "fixture-snippets:snippets/restore-fixture.yaml"
    }
  }
}

variables {
  proxmox_endpoint     = "https://proxmox.example.invalid:8006/"
  proxmox_ssh_username = "fixture"
  host = {
    node                 = "compute"
    ssh_address          = "192.0.2.2"
    vm_datastore_id      = "fixture-vm"
    snippet_datastore_id = "fixture-snippets"
    bridge               = "fixture-bridge"
    vlan_id              = 123
  }
  template = { node = "compute", vm_id = 199990 }
  lab = {
    vm_id      = 199991
    name       = "k8s-restore-fixture"
    cloud_user = "fixture"
    ssh_keys   = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureOnly fixture"]
  }
  production_vm_ids = [199981, 199982, 199983]
}

run "fenced_by_default" {
  command = plan
  assert {
    condition     = proxmox_virtual_environment_vm.scratch.network_device[0].disconnected
    error_message = "Default scratch NIC must be disconnected."
  }
  assert {
    condition     = proxmox_virtual_environment_vm.scratch.memory[0].dedicated == 4096 && proxmox_virtual_environment_vm.scratch.cpu[0].cores == 4
    error_message = "Qualification must fit its bounded capacity."
  }
  assert {
    condition     = !proxmox_virtual_environment_vm.scratch.on_boot && !proxmox_virtual_environment_vm.scratch.protection
    error_message = "The scratch guest is disposable and must not restart on host boot."
  }
  assert {
    condition     = proxmox_virtual_environment_vm.scratch.agent[0].wait_for_ip[0].disabled
    error_message = "A fenced guest must not wait for a DHCP lease."
  }
}

run "empty_prerequisite_provisioning_can_connect" {
  command = plan
  variables {
    fenced = false
  }
  assert {
    condition     = !proxmox_virtual_environment_vm.scratch.network_device[0].disconnected
    error_message = "Explicit empty-guest provisioning needs its reviewed bootstrap connection."
  }
}

run "production_id_refused" {
  command = plan
  variables {
    lab = {
      vm_id      = 199981
      name       = "k8s-restore-fixture"
      cloud_user = "fixture"
      ssh_keys   = ["synthetic-fixture-key"]
    }
  }
  expect_failures = [proxmox_virtual_environment_vm.scratch]
}

run "template_id_refused" {
  command = plan
  variables {
    lab = {
      vm_id      = 199990
      name       = "k8s-restore-fixture"
      cloud_user = "fixture"
      ssh_keys   = ["synthetic-fixture-key"]
    }
  }
  expect_failures = [proxmox_virtual_environment_vm.scratch]
}
