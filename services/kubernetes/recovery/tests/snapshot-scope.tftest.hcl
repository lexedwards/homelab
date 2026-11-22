mock_provider "vault" {}

variables {
  openbao_address = "https://bao.example.invalid"
  approle_mount   = "approle"
  enrollment_name = "test-server"
}

run "creation_scope_covers_current_and_historical_inventory_only" {
  command = plan
  variables {
    mode           = "create"
    s3_secret_path = "secret/data/kubernetes/test/snapshot-reader"
    backup         = { endpoint = "https://s3.example.invalid", bucket = "test-backups", region = "us-east-1" }
  }
  assert {
    condition = nonsensitive(
      tolist(output.snapshot_reader.policy.Statement[0].Action) == tolist(["s3:ListBucket", "s3:ListBucketVersions"]) &&
      tolist(output.snapshot_reader.policy.Statement[0].Resource) == tolist(["arn:aws:s3:::${var.backup.bucket}"]) &&
      output.enrollment.server_token_path == null
    )
    error_message = "Creation must produce bucket inventory scope for current objects and retained history, without object contents or an existing token."
  }
}

run "restore_scope_binds_getobject_to_selected_key" {
  command = plan
  variables {
    mode              = "restore"
    s3_secret_path    = "secret/data/kubernetes/test/snapshot-reader"
    server_token_path = "secret/data/kubernetes/test/server-token/0123456789ab"
    backup = {
      endpoint = "https://s3.example.invalid"
      bucket   = "test-backups"
      region   = "us-east-1"
      key      = "rke2/11111111-2222-4333-8444-555555555555/homelab-scheduled-test-source-1730000000.zip"
    }
  }
  assert {
    condition = nonsensitive(
      tolist(output.snapshot_reader.policy.Statement[0].Action) == tolist(["s3:GetObject"]) &&
      tolist(output.snapshot_reader.policy.Statement[0].Resource) == tolist(["arn:aws:s3:::${var.backup.bucket}/${var.backup.key}"]) &&
      output.enrollment.s3_secret_path == var.s3_secret_path &&
      output.enrollment.server_token_path == var.server_token_path
    )
    error_message = "Restore must export only the selected object content grant and exact independent credential/token records."
  }
}

run "join_exports_no_snapshot_account_or_writer" {
  command = plan
  variables {
    mode              = "join"
    server_token_path = "secret/data/kubernetes/test/server-token/0123456789ab"
  }
  assert {
    condition = nonsensitive(
      output.snapshot_reader == null && output.snapshot_value_enrollment == null &&
      output.enrollment.s3_secret_path == null && tolist(local.records) == tolist([var.server_token_path])
    )
    error_message = "Join must keep only existing-token read access and remove snapshot issuance/value-enrollment outputs."
  }
}
