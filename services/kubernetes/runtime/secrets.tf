locals {
  secrets_enabled               = nonsensitive(var.secrets_platform != null)
  secrets_qualification_enabled = local.secrets_enabled && nonsensitive(var.secrets_qualification != null)
  secrets_worker_names          = local.secrets_enabled ? nonsensitive(toset(keys(var.secrets_platform.workers))) : toset([])
  openbao_endpoint              = try(data.terraform_remote_state.openbao[0].outputs.api_endpoint, "https://disabled-openbao.invalid")
  cluster_connection            = try(data.terraform_remote_state.cluster[0].outputs.runtime_connection, { api_host = "https://disabled-cluster.invalid", ssh_user = "unconfigured", workers = [] })
  secrets_chart_template = local.secrets_enabled ? templatefile("${path.module}/../platform/secrets-csi.yaml.tftpl", {
    driver_chart   = filebase64("${path.module}/../vendor/secrets-store-csi-driver-1.6.2.tgz")
    provider_chart = filebase64("${path.module}/../vendor/openbao-0.30.7.tgz")
    api_audience   = jsonencode(var.secrets_platform.api_audience)
    bao_address    = jsonencode(local.openbao_endpoint)
  }) : ""
  secrets_charts = { for document in [for text in split("\n---\n", local.secrets_chart_template) : try(yamldecode(text), null)] : document.metadata.name => document if try(document.kind, "") == "HelmChart" }
  secrets_qualification_documents = {
    for document in [for text in split("\n---\n", file("${path.module}/../examples/secrets-workloads.yaml")) : yamldecode(text)] :
    "${document.kind}/${document.metadata.name}" => document
  }
}

provider "kubernetes" {
  config_path = try(var.secrets_platform.kubeconfig_path, null)
  host        = local.secrets_enabled ? local.cluster_connection.api_host : null
  insecure    = false
}

provider "vault" {
  address          = local.openbao_endpoint
  skip_child_token = true
  skip_tls_verify  = false
  token            = var.openbao_admin_token
}

data "terraform_remote_state" "openbao" {
  count   = local.secrets_enabled ? 1 : 0
  backend = "local"
  config  = { path = "${path.module}/../../openbao/terraform.tfstate" }
}

data "terraform_remote_state" "cluster" {
  count   = local.secrets_enabled ? 1 : 0
  backend = "local"
  config  = { path = "${path.module}/../terraform.tfstate" }
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
    filesha256("${path.module}/../scripts/label-secrets-provider.py"),
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
    inline = ["sudo -n python3 -B -c '${replace(file("${path.module}/../scripts/label-secrets-provider.py"), "'", "'\"'\"'")}' --apply"]
  }
  lifecycle {
    precondition {
      condition     = data.kubernetes_resource.secrets_worker[each.key].object.metadata.uid == var.secrets_platform.workers[each.key].node_uid
      error_message = "Worker identity changed. Reverify enrollment and pinned SSH trust before preparing its provider directory."
    }
    precondition {
      condition     = can(data.terraform_remote_state.cluster[0].outputs.runtime_connection) && toset(keys(var.secrets_platform.workers)) == toset(local.cluster_connection.workers)
      error_message = "Export reviewed cluster metadata from its canonical state and select its full worker set."
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
  manifest = local.secrets_charts[each.key]
  field_manager {
    name            = "homelab-opentofu"
    force_conflicts = false
  }
  depends_on = [kubernetes_namespace_v1.secrets_system, kubernetes_labels.secrets_worker]
  lifecycle {
    prevent_destroy = true
    precondition {
      condition = (
        filesha256("${path.module}/../vendor/secrets-store-csi-driver-1.6.2.tgz") == "2658657164b156c7759772a84ba83013ae2495a0b2d2e92ea6b2ad0738f623c4" &&
        filesha256("${path.module}/../vendor/openbao-0.30.7.tgz") == "fa4e6f3c1bbe936dc7ba079f1303ea56810af2f8600f046d8d5809860a4f980f"
      )
      error_message = "Vendored CSI/provider chart bytes differ from the reviewed pins."
    }
  }
}

resource "vault_auth_backend" "kubernetes" {
  count       = local.secrets_enabled ? 1 : 0
  type        = "kubernetes"
  path        = var.secrets_platform.auth_mount
  description = "Kubernetes workload identity; client JWT TokenReview with exact service-owned roles."
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = can(data.terraform_remote_state.openbao[0].outputs.api_endpoint)
      error_message = "Apply the reviewed OpenBao service endpoint output in its existing canonical state before enabling the secret platform."
    }
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

resource "kubernetes_namespace_v1" "secrets_qualification" {
  count = local.secrets_qualification_enabled ? 1 : 0
  metadata {
    name   = "secrets-check"
    labels = local.secrets_qualification_documents["Namespace/secrets-check"].metadata.labels
  }
}

resource "kubernetes_service_account_v1" "secrets_qualification" {
  count = local.secrets_qualification_enabled ? 1 : 0
  metadata {
    name      = "reader"
    namespace = kubernetes_namespace_v1.secrets_qualification[0].metadata[0].name
  }
  automount_service_account_token = false
}

module "secrets_qualification" {
  count             = local.secrets_qualification_enabled ? 1 : 0
  source            = "../modules/openbao-access"
  name              = "kubernetes-secrets-qualification"
  auth_mount        = vault_auth_backend.kubernetes[0].path
  openbao_endpoint  = local.openbao_endpoint
  api_audience      = var.secrets_platform.api_audience
  namespace         = kubernetes_namespace_v1.secrets_qualification[0].metadata[0].name
  service_account   = kubernetes_service_account_v1.secrets_qualification[0].metadata[0].name
  provider_class    = "qualification-files"
  token_review_role = kubernetes_cluster_role_v1.secrets_token_review[0].metadata[0].name
  files             = { value = { secret_path = var.secrets_qualification.secret_path, secret_key = "value" } }
  depends_on        = [vault_kubernetes_auth_backend_config.cluster, kubernetes_manifest.secrets_chart]
}

resource "kubernetes_config_map_v1" "secrets_reload_app" {
  count = local.secrets_qualification_enabled ? 1 : 0
  metadata {
    name      = "reload-app"
    namespace = kubernetes_namespace_v1.secrets_qualification[0].metadata[0].name
  }
  data = { "reload.py" = file("${path.module}/../examples/secret-reload.py") }
}

resource "kubernetes_manifest" "secrets_qualification_policy" {
  count      = local.secrets_qualification_enabled ? 1 : 0
  manifest   = local.secrets_qualification_documents["NetworkPolicy/qualification-isolation"]
  depends_on = [kubernetes_namespace_v1.secrets_qualification]
}

resource "kubernetes_manifest" "secrets_qualification_deployment" {
  for_each = local.secrets_qualification_enabled ? toset(["ordinary", "isolated"]) : toset([])
  manifest = merge(local.secrets_qualification_documents["Deployment/${each.key}"], {
    spec = merge(local.secrets_qualification_documents["Deployment/${each.key}"].spec, { replicas = var.secrets_qualification.replicas })
  })
  depends_on = [module.secrets_qualification, kubernetes_config_map_v1.secrets_reload_app, kubernetes_manifest.secrets_qualification_policy]
}
