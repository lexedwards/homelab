mock_provider "kubernetes" {}
mock_provider "vault" {}
mock_provider "external" {}

run "private_DNS_without_workload_secret_platform" {
  command = plan
  variables {
    cluster_api = {
      kubeconfig_path = "/synthetic/kubeconfig"
      api_host        = "https://api.example.invalid:6443"
    }
    private_dns_forwarding = {
      zone     = "internal.example.invalid"
      resolver = "192.0.2.53"
    }
  }
  assert {
    condition = yamldecode(kubernetes_manifest.private_dns_forwarding[0].manifest.spec.valuesContent).zoneFiles[0].contents == join("\n", [
      "internal.example.invalid:53 {", "    errors", "    cache 30", "    forward . 192.0.2.53", "}", ""
    ])
    error_message = "Private DNS must forward the exact suffix/resolver without requiring workload-secret delivery."
  }
}
