mock_provider "kubernetes" {
  mock_data "kubernetes_config_map_v1" {
    defaults = { data = { "ca.crt" = "synthetic-cluster-CA" } }
  }
  mock_data "kubernetes_resource" {
    defaults = {
      object = {
        metadata = { uid = "synthetic-worker-uid" }
        status   = { addresses = [{ type = "InternalIP", address = "192.0.2.21" }] }
      }
    }
  }
}
mock_provider "vault" {}
mock_provider "external" {
  mock_data "external" {
    defaults = { result = { content = "c3ludGhldGljLWNoYXJ0" } }
  }
}

run "secret_delivery_supports_one_reviewed_worker" {
  command = plan
  variables {
    cluster_api = {
      kubeconfig_path = "/synthetic/kubeconfig"
      api_host        = "https://api.example.invalid:6443"
      ssh_user        = "operator"
      workers         = ["only-worker"]
    }
    openbao_endpoint_file = abspath("./tests/openbao-endpoint.json")
    secrets_platform = {
      auth_mount   = "test-cluster"
      api_audience = "synthetic-audience"
      workers = {
        only-worker = { node_uid = "synthetic-worker-uid", host_key = "ssh-ed25519 dGVzdA==" }
      }
    }
  }
  assert {
    condition     = toset(keys(kubernetes_labels.secrets_worker)) == toset(["only-worker"])
    error_message = "Secret readiness must cover the reviewed worker cohort without requiring a fixed two-worker topology."
  }
  assert {
    condition     = kubernetes_manifest.secrets_chart["openbao-provider"].manifest.spec.chartContent == "c3ludGhldGljLWNoYXJ0"
    error_message = "The native chart definition must embed the verified download result."
  }
}
