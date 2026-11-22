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

run "disabled_publication_preserves_guarded_server_composition" {
  command = plan
  plan_options { target = [data.cloudinit_config.control_plane] }

  assert {
    condition = nonsensitive(local.control_plane_cloud_config == "#cloud-config\n${yamlencode(merge(local.node_baseline, local.server_config, {
      packages = concat(local.node_baseline.packages, ["jq", "python3-pyyaml"])
      write_files = concat(local.node_baseline.write_files, local.server_config.write_files, [
        for item in local.bootstrap_files : {
          path = item.path, owner = "root:root", permissions = item.mode, encoding = "b64", content = base64encode(item.content)
        }
      ])
    }))}")
    error_message = "Disabled publication must preserve the guarded server composition without adding publication assets."
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

run "restore_binds_selected_point_and_changes_node_without_changing_hostname" {
  command = plan
  plan_options { target = [data.cloudinit_config.control_plane] }
  variables {
    bootstrap_ssh_known_hosts_file = "./tests/publication.tftest.hcl"
    cluster_bootstrap = {
      mode                          = "restore"
      node_name                     = "test-replacement-node"
      fencing_confirmed             = true
      independent_custody_confirmed = true
      access = {
        address           = "https://bao.example.invalid"
        auth_mount        = "approle"
        role_name         = "kubernetes-test-bootstrap"
        role_id           = "11111111-2222-4333-8444-555555555555"
        reader_policy     = "kubernetes-test-bootstrap-read"
        s3_secret_path    = "secret/data/kubernetes/test/snapshot-reader"
        server_token_path = "secret/data/kubernetes/recovery/test/server-token/0123456789ab"
      }
      backup = { endpoint = "https://s3.example.invalid", bucket = "test-backups", region = "us-east-1" }
      recovery_point = {
        cluster_uid  = "11111111-2222-4333-8444-555555555555"
        key          = "rke2/11111111-2222-4333-8444-555555555555/homelab-scheduled-test-old-node-1730000000.zip"
        sha256       = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        size         = 4096
        token_hash   = "0123456789ab"
        source_node  = "test-old-node"
        timestamp    = 1730000000
        rke2_version = "v1.36.6+rke2r1"
        api_server   = "https://api.example.invalid:6443"
      }
    }
  }

  assert {
    condition = nonsensitive(
      jsondecode(base64decode(one([
        for item in yamldecode(local.control_plane_cloud_config).write_files : item.content
        if item.path == "/etc/rancher/rke2/bootstrap.json"
      ]))) == local.bootstrap_metadata &&
      local.bootstrap_metadata.recovery_point == var.cluster_bootstrap.recovery_point &&
      yamldecode(local.control_plane_cloud_config).hostname == var.control_plane.name &&
      yamldecode(local.control_plane_cloud_config).fqdn == var.control_plane.name &&
      yamldecode(local.rke2_config)["node-name"] == var.cluster_bootstrap.node_name &&
      local.bootstrap_metadata.configuration_sha256 == sha256(local.rke2_config)
    )
    error_message = "Restore composition must preserve its exact recovery point/configuration binding and VM hostname while choosing the distinct replacement Node name."
  }
}

run "join_composition_disables_initializer_publication" {
  command = plan
  plan_options { target = [data.cloudinit_config.control_plane] }
  variables {
    bootstrap_ssh_known_hosts_file   = "./tests/publication.tftest.hcl"
    publication_ssh_known_hosts_file = "./tests/publication.tftest.hcl"
    cluster_bootstrap = {
      mode        = "join"
      join_server = "https://registration.example.invalid:9345"
      access = {
        address           = "https://bao.example.invalid"
        auth_mount        = "approle"
        role_name         = "kubernetes-test-bootstrap"
        role_id           = "11111111-2222-4333-8444-555555555555"
        reader_policy     = "kubernetes-test-bootstrap-read"
        server_token_path = "secret/data/kubernetes/test/server-token/0123456789ab"
      }
    }
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
      yamldecode(local.rke2_config).server == var.cluster_bootstrap.join_server &&
      local.publication_target.initializer == false &&
      local.bootstrap_metadata.backup == null && local.bootstrap_metadata.recovery_point == null &&
      local.bootstrap_metadata.access.s3_secret_path == null
    )
    error_message = "Joining must preserve its registration endpoint without snapshot selection/access or initializer publication."
  }
}
