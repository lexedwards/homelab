mock_provider "vault" {}
mock_provider "kubernetes" {
  mock_data "kubernetes_config_map_v1" {
    defaults = { data = { "ca.crt" = "synthetic-public-ca" } }
  }
}
mock_provider "external" {
  mock_data "external" {
    defaults = { result = { content = "c3ludGhldGlj" } }
  }
}

override_data {
  target = data.terraform_remote_state.openbao[0]
  values = { outputs = { api_endpoint = "https://bao.example.invalid:8200" } }
}
override_data {
  target = data.terraform_remote_state.cluster[0]
  values = { outputs = { runtime_connection = { api_host = "https://api.example.invalid:6443", ssh_user = "testadmin", workers = ["worker-a", "worker-b"] } } }
}
override_data {
  target = data.kubernetes_resource.secrets_worker["worker-a"]
  values = { object = { metadata = { uid = "a" }, status = { addresses = [{ type = "InternalIP", address = "192.0.2.11" }] } } }
}
override_data {
  target = data.kubernetes_resource.secrets_worker["worker-b"]
  values = { object = { metadata = { uid = "b" }, status = { addresses = [{ type = "InternalIP", address = "192.0.2.12" }] } } }
}
variables {
  openbao_admin_token = "synthetic-administration"
  secrets_platform = {
    kubeconfig_path = "/synthetic/kubeconfig"
    auth_mount      = "kubernetes-test"
    api_audience    = "api-test"
    workers = {
      worker-a = { node_uid = "a", host_key = "ssh-ed25519 c3ludGhldGljLWhvc3Q=" }
      worker-b = { node_uid = "b", host_key = "ssh-ed25519 c3ludGhldGljLWhvc3Q=" }
    }
  }
  secrets_qualification = { secret_path = "apps/data/qualification" }
}

run "enroll_owned_service_writer_without_minting_a_token_or_populating_values" {
  command = plan
  assert {
    condition     = length(module.secrets_qualification) == 1 && length(module.secrets_qualification_delegation) == 1 && output.secrets_qualification_enrollment.token_role == "kubernetes-secrets-qualification-deploy"
    error_message = "Service-owned authorization must include a scoped writer grant, without issuing its credentials through state."
  }
}
