mock_provider "proxmox" {}
mock_provider "technitium" {}
mock_provider "cloudinit" {}

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

run "disabled_publication_preserves_existing_composition" {
  command = plan
  plan_options { target = [data.cloudinit_config.control_plane] }

  assert {
    condition = nonsensitive(local.control_plane_cloud_config == "#cloud-config\n${yamlencode(merge(local.node_baseline, local.server_config, {
      write_files = concat(local.node_baseline.write_files, local.server_config.write_files)
    }))}")
    error_message = "Disabled publication must preserve the original composed server cloud-config."
  }
}

run "enabled_publication_composes_assets_and_configuration_fingerprints" {
  command = plan
  plan_options { target = [data.cloudinit_config.control_plane] }
  variables {
    publication_ssh_known_hosts_file = "./tests/publication.tftest.hcl"
    publication_access = {
      address       = "https://bao.example.invalid"
      auth_mount    = "approle"
      role_name     = "kubernetes-11111111-2222-4333-8444-555555555555-kubeconfig"
      role_id       = "11111111-2222-4333-8444-555555555555"
      reader_policy = "kubernetes-11111111-2222-4333-8444-555555555555-kubeconfig-read"
      secret_path   = "secret/data/kubernetes/test/publication"
      publication = {
        endpoint    = "https://s3.example.invalid"
        bucket      = "test-configuration"
        region      = "us-east-1"
        cluster_uid = "11111111-2222-4333-8444-555555555555"
        api_server  = "https://api.example.invalid:6443"
      }
    }
  }

  assert {
    condition = nonsensitive(
      jsondecode(base64decode(one([
        for item in yamldecode(local.control_plane_cloud_config).write_files : item.content
        if item.path == "/etc/rancher/rke2/publication.json"
      ]))) == local.publication_target &&
      local.publication_target.rke2_config_sha256 == sha256(base64decode(one([
        for item in yamldecode(local.control_plane_cloud_config).write_files : item.content
        if item.path == "/etc/rancher/rke2/config.yaml"
      ])))
    )
    error_message = "Rendered metadata and the actual bootstrapped RKE2 configuration must share the exported identity/fingerprint."
  }

  assert {
    condition = nonsensitive(alltrue([
      for destination, asset in local.publication_assets : base64decode(one([
        for item in yamldecode(local.control_plane_cloud_config).write_files : item.content
        if item.path == destination
      ])) == file("${path.module}/${asset.source}")
    ]))
    error_message = "Every enabled publication asset must survive YAML/base64 composition unchanged."
  }

  assert {
    condition     = nonsensitive(alltrue([for package in local.node_baseline.packages : contains(yamldecode(local.control_plane_cloud_config).packages, package)]))
    error_message = "Publication role packages must not replace the shared node prerequisites."
  }
}
