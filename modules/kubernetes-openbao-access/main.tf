resource "vault_policy" "read" {
  name            = var.name
  allow_overwrite = false
  policy = join("\n", [for path in sort(distinct([for object in var.files : object.secret_path])) :
    "path ${jsonencode(path)} {\n  capabilities = [\"read\"]\n}\n"
  ])
}

resource "vault_kubernetes_auth_backend_role" "service" {
  backend                          = var.auth_mount
  role_name                        = var.name
  bound_service_account_names      = [var.service_account]
  bound_service_account_namespaces = [var.namespace]
  audience                         = var.api_audience
  alias_name_source                = "serviceaccount_uid"
  token_policies                   = [vault_policy.read.name]
  token_no_default_policy          = true
  token_ttl                        = 300
  token_max_ttl                    = 600
}

resource "kubernetes_cluster_role_binding_v1" "reviewer" {
  metadata { name = "openbao-review-${var.namespace}.${var.service_account}" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = var.token_review_role
  }
  subject {
    kind      = "ServiceAccount"
    name      = var.service_account
    namespace = var.namespace
  }
}

resource "kubernetes_manifest" "provider_class" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata   = { name = var.provider_class, namespace = var.namespace }
    spec = {
      provider = "openbao"
      parameters = {
        baoAddress       = var.openbao_endpoint
        baoAuthMountPath = var.auth_mount
        audience         = var.api_audience
        roleName         = vault_kubernetes_auth_backend_role.service.role_name
        objects = yamlencode([for name, object in var.files : {
          objectName     = name
          secretPath     = object.secret_path
          secretKey      = object.secret_key
          filePermission = 292
        }])
      }
    }
  }
  depends_on = [kubernetes_cluster_role_binding_v1.reviewer]
}
