locals {
  secrets_enabled      = nonsensitive(var.secrets_platform != null)
  secrets_worker_names = local.secrets_enabled ? nonsensitive(toset(keys(var.secrets_platform.workers))) : toset([])
  openbao_endpoint     = local.secrets_enabled ? coalesce(try(tostring(jsondecode(file(var.openbao_endpoint_file))), null), "https://disabled-openbao.invalid") : "https://disabled-openbao.invalid"
  secrets_chart_template = local.secrets_enabled ? templatefile("${path.module}/../platform/secrets-csi.yaml.tftpl", {
    driver_chart   = "downloaded-at-plan"
    provider_chart = "downloaded-at-plan"
    api_audience   = jsonencode(var.secrets_platform.api_audience)
    bao_address    = jsonencode(local.openbao_endpoint)
  }) : ""
  secrets_charts = { for document in [for text in split("\n---\n", local.secrets_chart_template) : try(yamldecode(text), null)] : document.metadata.name => document if try(document.kind, "") == "HelmChart" }
}

data "external" "secrets_chart" {
  for_each = local.secrets_enabled ? toset(["secrets-store-csi", "openbao-provider"]) : toset([])
  program  = ["python3", "-B", "${path.module}/../scripts/charts/download-chart.py"]
  query = {
    url    = local.secrets_charts[each.key].metadata.annotations["homelab.io/chart-source"]
    sha256 = local.secrets_charts[each.key].metadata.annotations["homelab.io/chart-sha256"]
  }
}

provider "vault" {
  address          = local.openbao_endpoint
  skip_child_token = true
  skip_tls_verify  = false
}

data "kubernetes_config_map_v1" "secrets_api_ca" {
  count = local.secrets_enabled ? 1 : 0
  metadata {
    name      = "kube-root-ca.crt"
    namespace = "kube-system"
  }
}

data "kubernetes_resource" "secrets_worker" {
  for_each    = local.secrets_worker_names
  api_version = "v1"
  kind        = "Node"
  metadata { name = each.key }
}

resource "terraform_data" "secrets_provider_directory" {
  for_each = local.secrets_worker_names
  triggers_replace = [
    data.kubernetes_resource.secrets_worker[each.key].object.metadata.uid,
    filesha256("${path.module}/../scripts/secrets/prepare-provider-directory.py"),
  ]
  connection {
    type     = "ssh"
    host     = one([for address in data.kubernetes_resource.secrets_worker[each.key].object.status.addresses : address.address if address.type == "InternalIP" && can(cidrnetmask("${address.address}/32"))])
    user     = local.cluster_connection.ssh_user
    agent    = true
    host_key = var.secrets_platform.workers[each.key].host_key
    timeout  = "30s"
  }
  provisioner "remote-exec" {
    inline = ["sudo -n python3 -B -c '${replace(file("${path.module}/../scripts/secrets/prepare-provider-directory.py"), "'", "'\"'\"'")}' --apply"]
  }
  lifecycle {
    precondition {
      condition     = data.kubernetes_resource.secrets_worker[each.key].object.metadata.uid == var.secrets_platform.workers[each.key].node_uid
      error_message = "Worker identity changed. Reverify enrollment and pinned SSH trust before preparing its provider directory."
    }
    precondition {
      condition     = toset(keys(var.secrets_platform.workers)) == local.cluster_connection.workers
      error_message = "Supply the reviewed infrastructure metadata and select its full worker cohort."
    }
  }
}

resource "kubernetes_labels" "secrets_worker" {
  for_each    = local.secrets_worker_names
  api_version = "v1"
  kind        = "Node"
  metadata { name = each.key }
  labels        = { "homelab.node-restriction.kubernetes.io/secrets-ready" = "true" }
  field_manager = "homelab-opentofu"
  force         = false
  depends_on    = [terraform_data.secrets_provider_directory]
  lifecycle {
    precondition {
      condition     = data.kubernetes_resource.secrets_worker_verified[each.key].object.metadata.uid == var.secrets_platform.workers[each.key].node_uid
      error_message = "Worker identity changed during preparation. Do not grant its secrets capability; repeat enrollment verification."
    }
  }
}

data "kubernetes_resource" "secrets_worker_verified" {
  for_each    = local.secrets_worker_names
  api_version = "v1"
  kind        = "Node"
  metadata { name = each.key }
  depends_on = [terraform_data.secrets_provider_directory]
}

resource "kubernetes_namespace_v1" "secrets_system" {
  count = local.secrets_enabled ? 1 : 0
  metadata {
    name   = "secrets-system"
    labels = { "pod-security.kubernetes.io/enforce" = "privileged" }
  }
  lifecycle { prevent_destroy = true }
}

resource "kubernetes_manifest" "secrets_chart" {
  for_each = local.secrets_enabled ? toset(["secrets-store-csi", "openbao-provider"]) : toset([])
  manifest = merge(local.secrets_charts[each.key], {
    spec = merge(local.secrets_charts[each.key].spec, { chartContent = data.external.secrets_chart[each.key].result.content })
  })
  field_manager {
    name            = "homelab-opentofu"
    force_conflicts = false
  }
  depends_on = [kubernetes_namespace_v1.secrets_system, kubernetes_labels.secrets_worker]
  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_auth_backend" "kubernetes" {
  count       = local.secrets_enabled ? 1 : 0
  type        = "kubernetes"
  path        = var.secrets_platform.auth_mount
  description = "Kubernetes workload identity; client JWT TokenReview with exact service-owned roles."
  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_kubernetes_auth_backend_config" "cluster" {
  count                  = local.secrets_enabled ? 1 : 0
  backend                = vault_auth_backend.kubernetes[0].path
  kubernetes_host        = local.cluster_connection.api_host
  kubernetes_ca_cert     = data.kubernetes_config_map_v1.secrets_api_ca[0].data["ca.crt"]
  token_reviewer_jwt     = ""
  disable_local_ca_jwt   = true
  disable_iss_validation = true
}

resource "kubernetes_cluster_role_v1" "secrets_token_review" {
  count = local.secrets_enabled ? 1 : 0
  metadata { name = "openbao-tokenreview" }
  rule {
    api_groups = ["authentication.k8s.io"]
    resources  = ["tokenreviews"]
    verbs      = ["create"]
  }
}
