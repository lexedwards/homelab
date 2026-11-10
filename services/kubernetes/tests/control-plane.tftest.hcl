mock_provider "proxmox" {
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "snippets:snippets/control-plane.yaml" }
  }
}
mock_provider "technitium" {}

# The VM mock leaves the NIC's computed MAC null. Plans must reject DNS publication
# without primary identity; successful lease discovery requires live validation.
variables {
  proxmox_endpoint     = "https://proxmox.example.invalid"
  proxmox_ssh_username = "testadmin"
  proxmox_nodes = {
    compute = { ssh_address = "compute.example.invalid", snippet_datastore_id = "snippets", vm_datastore_id = "vms", vm_bridge = "br-test" }
  }
  template = { vm_id = 100, node_name = "compute" }
  control_plane = {
    vm_id = 101
    name  = "test-server"
  }
  primary_vlan_id       = 100
  cloud_user            = "testadmin"
  cloud_ssh_public_keys = ["ssh-ed25519 c3ludGhldGljLWtleQ== test-fixture"]
  technitium_server_url = "https://dns.example.invalid"
  api_dns               = { zone = "example.invalid", name = "api.example.invalid" }
  cluster_networks      = { pods = "198.18.0.0/16", services = "198.19.0.0/16" }
}

run "protect_server_and_reject_unavailable_primary_identity" {
  command = plan
  assert {
    condition = nonsensitive(
      proxmox_virtual_environment_vm.control_plane.node_name == "compute" &&
      proxmox_virtual_environment_vm.control_plane.vm_id == 101 &&
      proxmox_virtual_environment_vm.control_plane.protection &&
      proxmox_virtual_environment_vm.control_plane.on_boot &&
      proxmox_virtual_environment_vm.control_plane.cpu[0].cores == 2 &&
      proxmox_virtual_environment_vm.control_plane.memory[0].dedicated == 4096 &&
      proxmox_virtual_environment_vm.control_plane.disk[0].size == 32 &&
      proxmox_virtual_environment_vm.control_plane.initialization[0].ip_config[0].ipv4[0].address == "dhcp"
    )
    error_message = "The server must be protected, explicitly identified and DHCP-addressed."
  }
  expect_failures = [technitium_record.api]
}

run "render_bootstrap_without_preselected_network_identity" {
  command = plan
  variables {
    control_plane = { vm_id = 101, name = "test-server" }
  }
  assert {
    condition = nonsensitive(
      !contains(keys(var.control_plane), "mac_address") &&
      !contains(keys(yamldecode(local.rke2_config)), "node-ip")
    )
    error_message = "Bootstrap rendering must not require a preselected IP or MAC."
  }
  expect_failures = [technitium_record.api]
}

run "bootstrap_without_secret_inputs_and_with_managed_cilium" {
  command = plan
  assert {
    condition = nonsensitive(try(
      yamldecode(local.cloud_init).disable_root &&
      !yamldecode(local.cloud_init).ssh_pwauth &&
      length(yamldecode(local.cloud_init).write_files) >= 3 &&
      yamldecode(local.rke2_config).selinux &&
      yamldecode(local.rke2_config).cni == "cilium" &&
      yamldecode(local.rke2_config)["disable-kube-proxy"] &&
      yamldecode(local.rke2_config)["tls-san"] == ["api.example.invalid"] &&
      !contains(keys(yamldecode(local.rke2_config)), "token") &&
      !contains(keys(yamldecode(local.rke2_config)), "token-file") &&
      yamldecode(yamldecode(local.cilium_config).spec.valuesContent).socketLB.hostNamespaceOnly &&
      yamldecode(yamldecode(local.cilium_config).spec.valuesContent).k8sServiceHost == "api.example.invalid" &&
      yamldecode(yamldecode(local.cilium_config).spec.valuesContent).k8sServicePort == 6443,
      false
    ))
    error_message = "Cloud-init must install the server without secret inputs and keep enforcing, explicit API identity and one managed Cilium owner."
  }
  expect_failures = [technitium_record.api]
}

run "render_exact_installer_pins_and_reboot_only_after_install_success" {
  command = plan
  assert {
    condition = nonsensitive(
      yamldecode(local.cloud_init).runcmd[2] == ["bash", "/usr/local/sbin/install-kubernetes-server", "1.36.6~rke2r1-0.el10", "0.24-1.el10"] &&
      yamldecode(local.cloud_init).power_state.mode == "reboot" &&
      yamldecode(local.cloud_init).power_state.condition == ["test", "-f", "/var/lib/kubernetes-server-installed"] &&
      strcontains(one([for f in yamldecode(local.cloud_init).write_files : f if f.path == "/etc/systemd/system/rke2-server.service.d/10-prerequisites.conf"]).content, "ConditionPathExists=/var/lib/kubernetes-server-installed") &&
      strcontains(one([for f in yamldecode(local.cloud_init).write_files : f if f.path == "/etc/systemd/system/rke2-server.service.d/10-prerequisites.conf"]).content, "ExecStartPre=/usr/local/sbin/kubernetes-node-preflight") &&
      base64decode(one([for f in yamldecode(local.cloud_init).write_files : f if f.path == "/usr/local/sbin/install-kubernetes-server"]).content) == file("${path.module}/cloud-init/install-server.sh") &&
      base64decode(one([for f in yamldecode(local.cloud_init).write_files : f if f.path == "/usr/local/sbin/kubernetes-node-preflight"]).content) == file("${path.module}/config/node-preflight.sh") &&
      one([for f in yamldecode(local.cloud_init).write_files : f if f.path == "/etc/rancher/rke2/config.yaml"]).permissions == "0600" &&
      !strcontains(local.cloud_init, "kubernetes-configure-server") &&
      !strcontains(local.cloud_init, "kubernetes-bootstrap-identity") &&
      !strcontains(local.cloud_init, "kubernetes-node-identity") &&
      !contains(keys(yamldecode(base64decode(one([for f in yamldecode(local.cloud_init).write_files : f if f.path == "/etc/rancher/rke2/config.yaml"]).content))), "node-ip") &&
      one([for f in yamldecode(local.cloud_init).write_files : f if f.path == "/home/testadmin/.ssh/authorized_keys"]).defer
    )
    error_message = "Rendered first boot must use exact package pins, protected server config, reviewed keys and the success-conditioned kernel reboot."
  }
  expect_failures = [technitium_record.api]
}

run "reject_template_identity_collision" {
  command = plan
  variables {
    control_plane = { vm_id = 100, name = "test-server" }
  }
  expect_failures = [proxmox_virtual_environment_vm.control_plane]
}

run "reject_overlapping_cluster_networks" {
  command = plan
  variables {
    cluster_networks = { pods = "198.18.0.0/15", services = "198.19.0.0/16" }
  }
  expect_failures = [proxmox_virtual_environment_vm.control_plane]
}

run "reject_host_bits_in_cluster_networks" {
  command = plan
  variables {
    cluster_networks = { pods = "198.18.0.1/16", services = "198.19.0.0/16" }
  }
  expect_failures = [var.cluster_networks]
}

run "reject_shell_content_in_package_version" {
  command = plan
  variables {
    rke2_version = "1.36.6~rke2r1-0.el10; false"
  }
  expect_failures = [var.rke2_version]
}

run "reject_invalid_dns_identity" {
  command = plan
  variables {
    api_dns = { zone = "example.invalid", name = "bad..example.invalid" }
  }
  expect_failures = [var.api_dns]
}
