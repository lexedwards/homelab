resource "kubernetes_manifest" "observability_api_identity" {
  count = local.observability_enabled ? 1 : 0
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "kubernetes-api-identity"
      namespace = kubernetes_namespace_v1.observability[0].metadata[0].name
    }
    spec = {
      endpointSelector = {}
      egress = [{
        toEntities = ["kube-apiserver"]
        toPorts = [{ ports = [
          { port = "443", protocol = "TCP" },
          { port = "6443", protocol = "TCP" },
        ] }]
      }]
    }
  }
  field_manager {
    name            = "homelab-opentofu"
    force_conflicts = false
  }
}

resource "kubernetes_manifest" "observability_node_identities" {
  count = local.observability_enabled ? 1 : 0
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumNetworkPolicy"
    metadata = {
      name      = "node-metrics-identities"
      namespace = kubernetes_namespace_v1.observability[0].metadata[0].name
    }
    spec = {
      endpointSelector = { matchLabels = { "homelab.io/telemetry-role" = "cluster" } }
      egress = [{
        toEntities = ["host", "remote-node", "kube-apiserver"]
        toPorts = [{ ports = [
          { port = "10250", protocol = "TCP" },
          { port = "9962", protocol = "TCP" },
          { port = "9963", protocol = "TCP" },
        ] }]
      }]
    }
  }
  field_manager {
    name            = "homelab-opentofu"
    force_conflicts = false
  }
}
