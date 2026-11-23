mock_provider "vault" {}
mock_provider "aws" {}

variables {
  openbao_address = "https://bao.example.invalid"
  approle_mount   = "approle"
  cluster_name    = "test-server"
  s3_endpoint     = "https://s3.example.invalid"
  records = {
    config_path             = "secret/data/kubernetes/test/config"
    identity_path           = "secret/data/kubernetes/test/identity"
    server_token_path       = "secret/data/kubernetes/test/server-token/0123456789ab"
    s3_secret_path          = "secret/data/kubernetes/test/backup-credentials"
    publication_secret_path = "secret/data/kubernetes/test/publication-credentials"
  }
}

run "enrollment_exports_exact_runtime_record_references" {
  command = plan
  assert {
    condition = nonsensitive(alltrue([
      for key, path in var.records : output.enrollment[key] == path
      ]) && output.enrollment.reader_policy == "${output.enrollment.role_name}-read" &&
    output.enrollment.cluster_name == var.cluster_name)
    error_message = "SSH enrollment must preserve exact record references and the stable cluster-name association."
  }
  assert {
    condition     = nonsensitive(tolist(output.configuration_enrollment.secret_paths) == tolist([var.records.config_path]))
    error_message = "The runtime-profile writer must not receive any token, identity or application-credential record."
  }
}
