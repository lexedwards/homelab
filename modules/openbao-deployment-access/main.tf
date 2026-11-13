locals {
  deployment_name = "${var.name}-deploy"
  issuer_name     = "${var.name}-issuer"
  deployment_policy = join("\n", concat([
    "path \"auth/token/lookup-self\" { capabilities = [\"read\"] }",
    "path \"auth/token/revoke-self\" { capabilities = [\"update\"] }",
  ], [for path in sort(tolist(var.secret_paths)) : "path ${jsonencode(path)} { capabilities = [\"create\", \"update\"] }"]))
}

resource "vault_policy" "deployment" {
  name            = local.deployment_name
  policy          = local.deployment_policy
  allow_overwrite = false
}

resource "vault_token_auth_backend_role" "deployment" {
  role_name               = local.deployment_name
  allowed_policies        = [vault_policy.deployment.name]
  disallowed_policies     = ["root", "default", var.name, local.issuer_name]
  orphan                  = false
  renewable               = false
  token_no_default_policy = true
  token_explicit_max_ttl  = 900
  token_type              = "service"
}

resource "vault_policy" "issuer" {
  name            = local.issuer_name
  allow_overwrite = false
  policy          = <<-POLICY
    path "auth/token/lookup-self" { capabilities = ["read"] }
    path "auth/token/revoke-self" { capabilities = ["update"] }
    path "auth/token/create/${vault_token_auth_backend_role.deployment.role_name}" {
      capabilities = ["update"]
      allowed_parameters = {
        "policies" = [["${local.deployment_name}"]]
        "ttl" = ["900s"]
        "explicit_max_ttl" = ["900s"]
        "renewable" = [false]
        "no_default_policy" = [true]
      }
      required_parameters = ["policies", "ttl", "explicit_max_ttl", "renewable", "no_default_policy"]
    }
  POLICY
}

output "enrollment" {
  sensitive = true
  value = {
    token_role        = vault_token_auth_backend_role.deployment.role_name
    deployment_policy = vault_policy.deployment.name
    issuer_policy     = vault_policy.issuer.name
    secret_paths      = sort(tolist(var.secret_paths))
  }
}
