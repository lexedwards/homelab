mock_provider "kubernetes" {
  mock_data "kubernetes_config_map_v1" {
    defaults = { data = { "ca.crt" = "synthetic-public-ca" } }
  }
  mock_data "kubernetes_resource" {
    defaults = { object = { metadata = { uid = "worker-a-uid" } } }
  }
}
mock_provider "vault" {}

override_data {
  target = data.terraform_remote_state.cluster[0]
  values = { outputs = { runtime_connection = { api_host = "https://api.example.invalid:6443", ssh_user = "testadmin", workers = ["test-worker-a", "test-worker-b"] } } }
}
override_data {
  target = data.terraform_remote_state.openbao[0]
  values = { outputs = { api_endpoint = "https://bao.example.invalid:8200" } }
}
override_data {
  target = data.kubernetes_resource.secrets_worker["test-worker-a"]
  values = { object = { metadata = { uid = "worker-a-uid" }, status = { addresses = [{ type = "InternalIP", address = "192.0.2.11" }] } } }
}
override_data {
  target = data.kubernetes_resource.secrets_worker["test-worker-b"]
  values = { object = { metadata = { uid = "worker-b-uid" }, status = { addresses = [{ type = "InternalIP", address = "192.0.2.12" }] } } }
}
override_data {
  target = data.kubernetes_resource.secrets_worker_verified["test-worker-a"]
  values = { object = { metadata = { uid = "worker-a-uid" } } }
}
override_data {
  target = data.kubernetes_resource.secrets_worker_verified["test-worker-b"]
  values = { object = { metadata = { uid = "worker-b-uid" } } }
}

variables {
  openbao_admin_token = "synthetic-ephemeral-administration"
  secrets_platform = {
    kubeconfig_path = "/synthetic/kubeconfig"
    auth_mount      = "kubernetes-test"
    api_audience    = "synthetic-api-audience"
    workers = {
      test-worker-a = { node_uid = "worker-a-uid", host_key = "ssh-ed25519 c3ludGhldGljLWhvc3Q=" }
      test-worker-b = { node_uid = "worker-b-uid", host_key = "ssh-ed25519 c3ludGhldGljLWhvc3Q=" }
    }
  }
}

run "disabled_platform_needs_no_cluster_or_openbao_objects" {
  command = plan
  variables { secrets_platform = null }
  assert {
    condition     = length(kubernetes_manifest.secrets_chart) == 0 && length(vault_auth_backend.kubernetes) == 0 && length(terraform_data.secrets_provider_directory) == 0
    error_message = "Opt-in platform resources must not affect the existing provisioning-only deployment."
  }
}

run "manage_native_charts_auth_and_host_prerequisites_without_secret_values" {
  command = plan
  assert {
    condition = (
      length(kubernetes_manifest.secrets_chart) == 2 &&
      kubernetes_manifest.secrets_chart["secrets-store-csi"].manifest.spec.targetNamespace == "secrets-system" &&
      yamldecode(kubernetes_manifest.secrets_chart["secrets-store-csi"].manifest.spec.valuesContent).tokenRequests[0].audience == "synthetic-api-audience" &&
      yamldecode(kubernetes_manifest.secrets_chart["openbao-provider"].manifest.spec.valuesContent).global.externalBaoAddr == "https://bao.example.invalid:8200" &&
      vault_auth_backend.kubernetes[0].path == "kubernetes-test" &&
      vault_kubernetes_auth_backend_config.cluster[0].kubernetes_host == "https://api.example.invalid:6443" &&
      vault_kubernetes_auth_backend_config.cluster[0].kubernetes_ca_cert == "synthetic-public-ca" &&
      vault_kubernetes_auth_backend_config.cluster[0].token_reviewer_jwt == "" &&
      vault_kubernetes_auth_backend_config.cluster[0].disable_local_ca_jwt &&
      length(terraform_data.secrets_provider_directory) == 2 &&
      kubernetes_labels.secrets_worker["test-worker-a"].labels["homelab.node-restriction.kubernetes.io/secrets-ready"] == "true" &&
      length(module.secrets_qualification) == 0
    )
    error_message = "OpenTofu must own the actual native chart, cluster auth and verified worker prerequisite resources, not merely export manifests or create secret values."
  }
}

run "reject_a_replaced_node_before_granting_capability_or_ssh_changes" {
  command = plan
  override_data {
    target = data.kubernetes_resource.secrets_worker["test-worker-a"]
    values = { object = { metadata = { uid = "unexpected-node-uid" }, status = { addresses = [{ type = "InternalIP", address = "192.0.2.11" }] } } }
  }
  expect_failures = [terraform_data.secrets_provider_directory["test-worker-a"]]
}

run "reject_partial_worker_selection" {
  command = plan
  variables {
    secrets_platform = {
      kubeconfig_path = "/synthetic/kubeconfig"
      auth_mount      = "kubernetes-test"
      api_audience    = "synthetic-api-audience"
      workers         = { test-worker-a = { node_uid = "worker-a-uid", host_key = "ssh-ed25519 c3ludGhldGljLWhvc3Q=" } }
    }
  }
  expect_failures = [var.secrets_platform]
}

run "manage_parked_qualification_as_resources_not_secret_values" {
  command = plan
  variables { secrets_qualification = { secret_path = "apps/data/qualification" } }
  assert {
    condition = (
      length(module.secrets_qualification) == 1 &&
      kubernetes_service_account_v1.secrets_qualification[0].metadata[0].name == "reader" &&
      !kubernetes_service_account_v1.secrets_qualification[0].automount_service_account_token &&
      kubernetes_manifest.secrets_qualification_deployment["ordinary"].manifest.spec.replicas == 0 &&
      kubernetes_manifest.secrets_qualification_deployment["isolated"].manifest.spec.replicas == 0 &&
      kubernetes_manifest.secrets_qualification_deployment["isolated"].manifest.spec.template.spec.runtimeClassName == "kata-clh-runtime-rs"
    )
    error_message = "Qualification must be resource-owned, explicit-runtime and initially parked until out-of-band synthetic value enrollment."
  }
}

run "reject_missing_service_owned_endpoint_before_any_apply" {
  command = plan
  override_data {
    target = data.terraform_remote_state.openbao[0]
    values = { outputs = {} }
  }
  expect_failures = [vault_auth_backend.kubernetes[0]]
}

run "reject_a_worker_cohort_different_from_the_infrastructure_definition" {
  command = plan
  override_data {
    target = data.terraform_remote_state.cluster[0]
    values = { outputs = { runtime_connection = { api_host = "https://api.example.invalid:6443", ssh_user = "testadmin", workers = ["test-worker-a", "unapproved-worker"] } } }
  }
  expect_failures = [terraform_data.secrets_provider_directory["test-worker-a"], terraform_data.secrets_provider_directory["test-worker-b"]]
}
