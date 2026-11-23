mock_provider "proxmox" {
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "test-snippets:snippets/test.yaml" }
  }
}
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
  }
  template              = { vm_id = 900, node_name = "compute" }
  control_plane         = { vm_id = 901, name = "test-control-plane" }
  primary_vlan_id       = 100
  cloud_user            = "operator"
  cloud_ssh_public_keys = ["ssh-ed25519 dGVzdA=="]
  api_dns               = { zone = "example.invalid", name = "api.example.invalid" }
  cluster_networks      = { pods = "198.18.0.0/16", services = "198.19.0.0/16" }
}

run "render_immutable_installation" {
  command = plan
  plan_options { target = [data.cloudinit_config.control_plane] }
  assert {
    condition = nonsensitive(alltrue([
      for destination, asset in local.bootstrap_assets : base64decode(one([
        for item in yamldecode(local.control_plane_cloud_config).write_files : item.content if item.path == destination
      ])) == file("${path.module}/${asset.source}")
    ]))
    error_message = "Static server tools must survive YAML/base64 composition unchanged."
  }
}

run "render_installation_with_separate_enrollment" {
  command = plan
  plan_options { target = [data.cloudinit_config.control_plane] }
  variables {
    bootstrap_enrollment_revision  = "changed-enrollment-only"
    bootstrap_ssh_known_hosts_file = "./tests/bootstrap.tftest.hcl"
    bootstrap_access = {
      address                 = "https://bao.example.invalid"
      auth_mount              = "approle"
      role_name               = "kubernetes-test-cluster-bootstrap"
      role_id                 = "11111111-2222-4333-8444-555555555555"
      reader_policy           = "kubernetes-test-cluster-bootstrap-read"
      cluster_name            = "test-cluster"
      identity_token_role     = "kubernetes-test-cluster-identity"
      identity_writer_policy  = "kubernetes-test-cluster-identity"
      config_path             = "secret/data/kubernetes/test/profile"
      identity_path           = "secret/data/kubernetes/test/identity"
      server_token_path       = "secret/data/kubernetes/test/server-token/0123456789ab"
      s3_secret_path          = "secret/data/kubernetes/test/backup"
      publication_secret_path = "secret/data/kubernetes/test/publication"
    }
  }
  assert {
    condition = nonsensitive(yamldecode(base64decode(one([
      for item in yamldecode(local.control_plane_cloud_config).write_files : item.content if item.path == "/etc/rancher/rke2/config.yaml"
    ])))["node-name"] == var.control_plane.name)
    error_message = "Runtime enrollment must preserve the VM's stable base Node-name configuration."
  }
}
