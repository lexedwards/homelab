provider "kubernetes" {
  config_path = var.cluster_api.kubeconfig_path
  host        = var.cluster_api.api_host
  insecure    = false
}

provider "vault" {
  address          = var.qualification.openbao_address
  skip_child_token = true
  skip_tls_verify  = false
}

locals {
  documents = {
    for document in [for text in split("\n---\n", file("${path.module}/../secrets-workloads.yaml")) : yamldecode(text)] :
    "${document.kind}/${document.metadata.name}" => document
  }
}

resource "kubernetes_namespace_v1" "qualification" {
  metadata {
    name   = "secrets-check"
    labels = local.documents["Namespace/secrets-check"].metadata.labels
  }
}

resource "kubernetes_service_account_v1" "reader" {
  metadata {
    name      = "reader"
    namespace = kubernetes_namespace_v1.qualification.metadata[0].name
  }
  automount_service_account_token = false
}

module "value_enrollment" {
  source       = "../../../../modules/openbao-deployment-access"
  name         = "kubernetes-secrets-qualification"
  secret_paths = [var.qualification.secret_path]
}

module "reader" {
  source            = "../../../../modules/kubernetes-openbao-access"
  name              = "kubernetes-secrets-qualification"
  auth_mount        = var.qualification.auth_mount
  openbao_endpoint  = var.qualification.openbao_address
  api_audience      = var.qualification.api_audience
  namespace         = kubernetes_namespace_v1.qualification.metadata[0].name
  service_account   = kubernetes_service_account_v1.reader.metadata[0].name
  provider_class    = "qualification-files"
  token_review_role = "openbao-tokenreview"
  files             = { value = { secret_path = var.qualification.secret_path, secret_key = "value" } }
}

resource "kubernetes_config_map_v1" "reload_app" {
  metadata {
    name      = "reload-app"
    namespace = kubernetes_namespace_v1.qualification.metadata[0].name
  }
  data = { "reload.py" = file("${path.module}/../secret-reload.py") }
}

resource "kubernetes_manifest" "policy" {
  manifest   = local.documents["NetworkPolicy/qualification-isolation"]
  depends_on = [kubernetes_namespace_v1.qualification]
}

resource "kubernetes_manifest" "deployment" {
  for_each = toset(["ordinary", "isolated"])
  manifest = merge(local.documents["Deployment/${each.key}"], {
    spec = merge(local.documents["Deployment/${each.key}"].spec, { replicas = var.qualification.replicas })
  })
  depends_on = [module.reader, kubernetes_config_map_v1.reload_app, kubernetes_manifest.policy]
}

output "value_enrollment" {
  description = "Non-secret exact-record writer/issuer metadata only; populate the synthetic value out of band."
  sensitive   = true
  value       = merge(module.value_enrollment.enrollment, { address = var.qualification.openbao_address })
}
