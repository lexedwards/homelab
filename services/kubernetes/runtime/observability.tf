locals {
  observability_enabled = nonsensitive(var.observability != null)
  observability_chart   = jsondecode(file("${path.module}/../platform/observability/chart.json"))
  observability_base    = yamldecode(file("${path.module}/../platform/observability/values.yaml"))
  observability_values = local.observability_enabled ? merge(local.observability_base, {
    cluster = { name = var.observability.cluster_name }
    destinations = {
      warehouse = merge(local.observability_base.destinations.warehouse, {
        url = var.observability.warehouse_url
        tls = { insecure = startswith(var.observability.warehouse_url, "http://"), insecureSkipVerify = false }
      })
    }
  }) : null
}

data "external" "observability_chart" {
  count   = local.observability_enabled ? 1 : 0
  program = ["python3", "-B", "${path.module}/../scripts/charts/download-chart.py"]
  query = {
    url    = local.observability_chart.url
    sha256 = local.observability_chart.sha256
  }
}

resource "kubernetes_namespace_v1" "observability" {
  count = local.observability_enabled ? 1 : 0
  metadata {
    name = "observability-system"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
  lifecycle { prevent_destroy = true }
}

resource "kubernetes_network_policy_v1" "observability_default" {
  count = local.observability_enabled ? 1 : 0
  metadata {
    name      = "default-deny"
    namespace = kubernetes_namespace_v1.observability[0].metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy_v1" "observability_dns" {
  count = local.observability_enabled ? 1 : 0
  metadata {
    name      = "dns"
    namespace = kubernetes_namespace_v1.observability[0].metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Egress"]
    egress {
      to {
        ip_block { cidr = "${var.observability.dns_ipv4}/32" }
      }
      ports {
        protocol = "UDP"
        port     = "53"
      }
      ports {
        protocol = "TCP"
        port     = "53"
      }
    }
    egress {
      to {
        namespace_selector { match_labels = { "kubernetes.io/metadata.name" = "kube-system" } }
        pod_selector { match_labels = { "k8s-app" = "kube-dns" } }
      }
      ports {
        protocol = "UDP"
        port     = "53"
      }
      ports {
        protocol = "TCP"
        port     = "53"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "observability_api" {
  count = local.observability_enabled ? 1 : 0
  metadata {
    name      = "kubernetes-api"
    namespace = kubernetes_namespace_v1.observability[0].metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Egress"]
    egress {
      dynamic "to" {
        for_each = var.observability.api_ipv4_addresses
        content {
          ip_block { cidr = "${to.value}/32" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
      ports {
        protocol = "TCP"
        port     = "6443"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "observability_scrape" {
  count = local.observability_enabled ? 1 : 0
  metadata {
    name      = "cluster-scrapes"
    namespace = kubernetes_namespace_v1.observability[0].metadata[0].name
  }
  spec {
    pod_selector { match_labels = { "homelab.io/telemetry-role" = "cluster" } }
    policy_types = ["Ingress", "Egress"]
    ingress {
      from {
        pod_selector { match_labels = { "homelab.io/telemetry-role" = "cluster" } }
      }
      ports {
        protocol = "TCP"
        port     = "12345"
      }
    }
    egress {
      dynamic "to" {
        for_each = var.observability.node_ipv4_addresses
        content {
          ip_block { cidr = "${to.value}/32" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "10250"
      }
      ports {
        protocol = "TCP"
        port     = "9962"
      }
      ports {
        protocol = "TCP"
        port     = "9963"
      }
    }
    egress {
      to {
        pod_selector { match_labels = { "app.kubernetes.io/name" = "kube-state-metrics" } }
      }
      ports {
        protocol = "TCP"
        port     = "8080"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "observability_state_metrics" {
  count = local.observability_enabled ? 1 : 0
  metadata {
    name      = "state-metrics"
    namespace = kubernetes_namespace_v1.observability[0].metadata[0].name
  }
  spec {
    pod_selector { match_labels = { "app.kubernetes.io/name" = "kube-state-metrics" } }
    policy_types = ["Ingress"]
    ingress {
      from {
        pod_selector { match_labels = { "homelab.io/telemetry-role" = "cluster" } }
      }
      ports {
        protocol = "TCP"
        port     = "8080"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "observability_export" {
  count = local.observability_enabled ? 1 : 0
  metadata {
    name      = "warehouse-export"
    namespace = kubernetes_namespace_v1.observability[0].metadata[0].name
  }
  spec {
    pod_selector { match_labels = { "homelab.io/telemetry-exporter" = "true" } }
    policy_types = ["Egress"]
    egress {
      to {
        ip_block { cidr = "${var.observability.warehouse_ipv4}/32" }
      }
      ports {
        protocol = "TCP"
        port     = tostring(var.observability.warehouse_port)
      }
    }
  }
}

resource "kubernetes_manifest" "observability_chart" {
  count = local.observability_enabled ? 1 : 0
  manifest = {
    apiVersion = "helm.cattle.io/v1"
    kind       = "HelmChart"
    metadata   = { name = "observability", namespace = "kube-system" }
    spec = {
      chartContent    = data.external.observability_chart[0].result.content
      targetNamespace = kubernetes_namespace_v1.observability[0].metadata[0].name
      timeout         = "10m0s"
      failurePolicy   = "retry"
      backOffLimit    = 0
      valuesContent   = yamlencode(local.observability_values)
    }
  }
  field_manager {
    name            = "homelab-opentofu"
    force_conflicts = false
  }
  depends_on = [
    kubernetes_network_policy_v1.observability_default,
    kubernetes_network_policy_v1.observability_dns,
    kubernetes_network_policy_v1.observability_api,
    kubernetes_network_policy_v1.observability_scrape,
    kubernetes_network_policy_v1.observability_state_metrics,
    kubernetes_network_policy_v1.observability_export,
    kubernetes_manifest.observability_api_identity,
    kubernetes_manifest.observability_node_identities,
  ]
  lifecycle { prevent_destroy = true }
}
