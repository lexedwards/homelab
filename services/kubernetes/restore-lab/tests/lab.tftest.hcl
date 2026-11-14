mock_provider "proxmox" {
  mock_resource "proxmox_virtual_environment_file" {
    defaults = {
      id = "fixture-snippets:snippets/restore-fixture.yaml"
    }
  }
}

run "bootstrap_empty_fixture" {
  command = apply
  variables {
    fenced = false
  }
}

run "bootstrap_content_is_immutable_but_nic_can_be_fenced" {
  command = plan
  variables {
    allow_unconfined_guest_exec = true
    fenced                     = true
  }
  assert {
    condition = (
      one([for step in yamldecode(proxmox_virtual_environment_file.bootstrap.source_raw[0].data).runcmd : step[2] if step[0] == "bash"]) == "false" &&
      one([for step in yamldecode(local.user_data).runcmd : step[2] if step[0] == "bash"]) == "true" &&
      proxmox_virtual_environment_vm.scratch.initialization[0].user_data_file_id == proxmox_virtual_environment_file.bootstrap.id &&
      proxmox_virtual_environment_vm.scratch.network_device[0].disconnected
    )
    error_message = "First-boot content must remain unchanged without preventing NIC fencing."
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
    condition     = !var.allow_unconfined_guest_exec && one([for step in yamldecode(local.user_data).runcmd : step[2] if step[0] == "bash"]) == "false"
    error_message = "Administrative SELinux relaxation must default off and reach bootstrap as an explicit string."
  }
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

run "explicit_lab_admin_policy_opt_in" {
  command = plan
  variables {
    allow_unconfined_guest_exec = true
  }
  assert {
    condition     = one([for step in yamldecode(local.user_data).runcmd : step[2] if step[0] == "bash"]) == "true"
    error_message = "Approved lab-only opt-in must reach the policy support/verification gate."
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
