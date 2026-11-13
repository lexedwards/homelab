mock_provider "vault" {}

variables {
  name         = "demo-reader"
  secret_paths = ["apps/data/demo"]
}

run "bound_writer_issuance_and_exact_records_without_default_or_orphan_tokens" {
  command = plan
  module { source = "../../openbao/modules/deployment-access" }
  assert {
    condition = (
      toset(vault_token_auth_backend_role.deployment.allowed_policies) == toset(["demo-reader-deploy"]) &&
      vault_token_auth_backend_role.deployment.token_explicit_max_ttl == 900 &&
      vault_token_auth_backend_role.deployment.token_no_default_policy &&
      !vault_token_auth_backend_role.deployment.renewable &&
      !vault_token_auth_backend_role.deployment.orphan &&
      !vault_policy.deployment.allow_overwrite &&
      !vault_policy.issuer.allow_overwrite &&
      output.enrollment.secret_paths == tolist(["apps/data/demo"])
    )
    error_message = "Writer issuance must be bounded, non-renewable, parented and restricted to its exact deployment policy/records."
  }
}

run "reject_wildcard_value_paths" {
  command = plan
  module { source = "../../openbao/modules/deployment-access" }
  variables { secret_paths = ["apps/data/*"] }
  expect_failures = [var.secret_paths]
}

run "reject_reserved_or_traversal_paths" {
  command = plan
  module { source = "../../openbao/modules/deployment-access" }
  variables { secret_paths = ["sys/data/unrelated", "apps/data/../unrelated"] }
  expect_failures = [var.secret_paths]
}

run "reject_names_that_escape_the_service_scope" {
  command = plan
  module { source = "../../openbao/modules/deployment-access" }
  variables { name = "demo/*" }
  expect_failures = [var.name]
}
