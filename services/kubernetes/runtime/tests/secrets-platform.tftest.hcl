mock_provider "kubernetes" {
  mock_data "kubernetes_config_map_v1" {
    defaults = { data = { "ca.crt" = "synthetic-public-ca" } }
  }
  mock_data "kubernetes_resource" {
    defaults = { object = { metadata = { uid = "worker-a-uid" } } }
  }
  mock_data "kubernetes_namespace_v1" {
    defaults = { metadata = { uid = "00000000-0000-0000-0000-000000000001" } }
  }
}
mock_provider "vault" {}
mock_provider "external" {
  mock_data "external" {
    defaults = { result = { content = "c3ludGhldGljLWNoYXJ0" } }
  }
}

override_data {
  target = data.terraform_remote_state.cluster[0]
  values = { outputs = { runtime_connection = { api_host = "https://api.example.invalid:6443", ssh_user = "testadmin", workers = ["test-worker-a", "test-worker-b"] } } }
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
  openbao_endpoint_file = abspath("tests/fixtures/openbao-endpoint.json")
  openbao_admin_token   = "synthetic-ephemeral-administration"
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

run "private_dns_forwarding_is_opt_in" {
  command = plan
  assert {
    condition     = length(kubernetes_manifest.private_dns_forwarding) == 0
    error_message = "Private-zone routing must not alter an unconfigured cluster."
  }
}

run "forward_only_the_declared_private_zone_without_replacing_native_servers" {
  command = plan
  variables { private_dns_forwarding = { zone = "lab.example.invalid", resolver = "192.0.2.53" } }
  assert {
    condition = (
      kubernetes_manifest.private_dns_forwarding[0].manifest.kind == "HelmChartConfig" &&
      kubernetes_manifest.private_dns_forwarding[0].manifest.metadata.name == "rke2-coredns" &&
      kubernetes_manifest.private_dns_forwarding[0].manifest.metadata.namespace == "kube-system" &&
      yamldecode(kubernetes_manifest.private_dns_forwarding[0].manifest.spec.valuesContent).extraConfig.import.parameters == "/etc/coredns/private-forward.server" &&
      yamldecode(kubernetes_manifest.private_dns_forwarding[0].manifest.spec.valuesContent).zoneFiles == [{
        filename = "private-forward.server"
        contents = "lab.example.invalid:53 {\n    errors\n    cache 30\n    forward . 192.0.2.53\n}\n"
      }] &&
      !contains(keys(yamldecode(kubernetes_manifest.private_dns_forwarding[0].manifest.spec.valuesContent)), "servers")
    )
    error_message = "Use the native chart's import and mounted config file without replacing cluster/public DNS servers or adopting its HelmChart."
  }
}

run "reject_private_dns_directive_injection" {
  command = plan
  variables { private_dns_forwarding = { zone = "lab.example.invalid\n.:53", resolver = "192.0.2.53" } }
  expect_failures = [var.private_dns_forwarding]
}

run "reject_private_dns_cluster_zone_override" {
  command = plan
  variables { private_dns_forwarding = { zone = "cluster.local", resolver = "192.0.2.53" } }
  expect_failures = [var.private_dns_forwarding]
}

run "reject_private_dns_resolver_directive_injection" {
  command = plan
  variables { private_dns_forwarding = { zone = "lab.example.invalid", resolver = "192.0.2.53\n    forward . 127.0.0.1" } }
  expect_failures = [var.private_dns_forwarding]
}

run "manage_native_charts_auth_and_host_prerequisites_without_secret_values" {
  command = plan
  assert {
    condition = (
      length(kubernetes_manifest.secrets_chart) == 2 &&
      kubernetes_manifest.secrets_chart["secrets-store-csi"].manifest.spec.chartContent == "c3ludGhldGljLWNoYXJ0" &&
      data.external.secrets_chart["secrets-store-csi"].query.url == "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts/secrets-store-csi-driver-1.6.2.tgz" &&
      data.external.secrets_chart["openbao-provider"].query.sha256 == "fa4e6f3c1bbe936dc7ba079f1303ea56810af2f8600f046d8d5809860a4f980f" &&
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

run "recovery_custody_has_no_resources_until_explicitly_enabled" {
  command = plan
  assert {
    condition     = length(module.recovery_deployment_access) == 0
    error_message = "Recovery authorization must remain opt-in and never mint values or credentials."
  }
}

run "recovery_writer_owns_only_two_fingerprint_bound_records_and_no_workload_reader" {
  command = plan
  variables {
    recovery_custody = {
      kv_v2_mount              = "apps"
      cluster_uid              = "00000000-0000-0000-0000-000000000001"
      server_token_hash        = "aaaaaaaaaaaa"
      backup_credential_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  }
  assert {
    condition = (
      length(module.recovery_deployment_access) == 1 &&
      toset(module.recovery_deployment_access[0].enrollment.secret_paths) == toset([
        "apps/data/kubernetes/recovery/00000000-0000-0000-0000-000000000001/server-token/aaaaaaaaaaaa",
        "apps/data/kubernetes/recovery/00000000-0000-0000-0000-000000000001/s3-credentials/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      ]) &&
      toset(output.recovery_custody_enrollment.records.server_token.fields) == toset(["server_token"]) &&
      toset(output.recovery_custody_enrollment.records.s3_credentials.fields) == toset(["access_key_id", "secret_access_key"]) &&
      length(module.secrets_qualification) == 0
    )
    error_message = "Recovery enrollment needs exact fingerprint-addressed schemas and a separate bounded writer, not workload-reader access or values in state."
  }
}

run "recovery_custody_rejects_a_different_initialized_cluster" {
  command = plan
  variables {
    recovery_custody = {
      kv_v2_mount              = "apps"
      cluster_uid              = "00000000-0000-0000-0000-000000000002"
      server_token_hash        = "aaaaaaaaaaaa"
      backup_credential_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  }
  expect_failures = [data.kubernetes_namespace_v1.recovery_cluster[0]]
}

run "recovery_fingerprints_are_metadata_not_plain_values" {
  command = plan
  variables {
    recovery_custody = {
      kv_v2_mount              = "apps"
      cluster_uid              = "00000000-0000-0000-0000-000000000001"
      server_token_hash        = "not-a-native-fingerprint"
      backup_credential_sha256 = "bb"
    }
  }
  expect_failures = [var.recovery_custody]
}

run "recovery_without_runtime_inputs_does_not_fetch_a_cluster" {
  command = plan
  variables {
    secrets_platform = null
    recovery_custody = {
      kv_v2_mount              = "apps"
      cluster_uid              = "00000000-0000-0000-0000-000000000001"
      server_token_hash        = "aaaaaaaaaaaa"
      backup_credential_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  }
  expect_failures = [var.recovery_custody]
  assert {
    condition     = length(data.kubernetes_namespace_v1.recovery_cluster) == 0 && length(module.recovery_deployment_access) == 0
    error_message = "Invalid recovery configuration must not fall back to ambient Kubernetes configuration."
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
  variables { openbao_endpoint_file = "/synthetic/missing-published-endpoint" }
  expect_failures = [var.openbao_endpoint_file]
}

run "reject_a_credential_bearing_endpoint_export" {
  command = plan
  variables { openbao_endpoint_file = abspath("tests/fixtures/invalid-openbao-endpoint.json") }
  expect_failures = [var.openbao_endpoint_file]
}

run "reject_a_null_endpoint_export" {
  command = plan
  variables { openbao_endpoint_file = abspath("tests/fixtures/null-openbao-endpoint.json") }
  expect_failures = [var.openbao_endpoint_file]
}

run "reject_a_worker_cohort_different_from_the_infrastructure_definition" {
  command = plan
  override_data {
    target = data.terraform_remote_state.cluster[0]
    values = { outputs = { runtime_connection = { api_host = "https://api.example.invalid:6443", ssh_user = "testadmin", workers = ["test-worker-a", "unapproved-worker"] } } }
  }
  expect_failures = [terraform_data.secrets_provider_directory["test-worker-a"], terraform_data.secrets_provider_directory["test-worker-b"]]
}
