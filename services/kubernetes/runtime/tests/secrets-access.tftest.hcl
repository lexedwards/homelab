mock_provider "vault" {}
mock_provider "kubernetes" {}

variables {
  name              = "demo-reader"
  auth_mount        = "kubernetes-test"
  openbao_endpoint  = "https://bao.example.invalid:8200"
  api_audience      = "api-test"
  namespace         = "demo"
  service_account   = "reader"
  provider_class    = "files"
  token_review_role = "openbao-tokenreview"
  files = {
    password = { secret_path = "apps/data/demo", secret_key = "password" }
    username = { secret_path = "apps/data/demo", secret_key = "username" }
  }
}

run "manage_exact_record_policy_role_binding_and_class_without_populated_values" {
  command = plan
  module { source = "../modules/openbao-access" }
  assert {
    condition = (
      vault_policy.read.policy == "path \"apps/data/demo\" {\n  capabilities = [\"read\"]\n}\n" &&
      !vault_policy.read.allow_overwrite &&
      toset(vault_kubernetes_auth_backend_role.service.bound_service_account_names) == toset(["reader"]) &&
      toset(vault_kubernetes_auth_backend_role.service.bound_service_account_namespaces) == toset(["demo"]) &&
      vault_kubernetes_auth_backend_role.service.audience == "api-test" &&
      vault_kubernetes_auth_backend_role.service.token_no_default_policy &&
      vault_kubernetes_auth_backend_role.service.token_ttl == 300 &&
      vault_kubernetes_auth_backend_role.service.token_max_ttl == 600 &&
      kubernetes_cluster_role_binding_v1.reviewer.metadata[0].name == "openbao-review-demo.reader" &&
      kubernetes_cluster_role_binding_v1.reviewer.role_ref[0].name == "openbao-tokenreview" &&
      kubernetes_manifest.provider_class.manifest.spec.parameters.baoAddress == "https://bao.example.invalid:8200" &&
      !contains(keys(kubernetes_manifest.provider_class.manifest.spec), "secretObjects") &&
      length(yamldecode(kubernetes_manifest.provider_class.manifest.spec.parameters.objects)) == 2 &&
      alltrue([for object in yamldecode(kubernetes_manifest.provider_class.manifest.spec.parameters.objects) : object.filePermission == 292])
    )
    error_message = "Service definitions must own exact record access and account identity, without overwriting unrelated policy or synchronizing secret values."
  }
}

run "reject_wildcard_record_access" {
  command = plan
  module { source = "../modules/openbao-access" }
  variables { files = { value = { secret_path = "apps/data/*", secret_key = "value" } } }
  expect_failures = [var.files]
}

run "reject_wildcard_service_accounts" {
  command = plan
  module { source = "../modules/openbao-access" }
  variables { service_account = "*" }
  expect_failures = [var.name]
}

run "reject_plaintext_openbao_transport" {
  command = plan
  module { source = "../modules/openbao-access" }
  variables { openbao_endpoint = "http://bao.example.invalid:8200" }
  expect_failures = [var.openbao_endpoint]
}
