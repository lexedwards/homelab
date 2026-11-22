variable "publication_access" {
  description = "Opt-in non-secret artifacts-root enrollment export. The application S3 credential remains in OpenBao, never in this input."
  type = object({
    address       = string
    auth_mount    = string
    role_name     = string
    role_id       = string
    reader_policy = string
    secret_path   = string
    publication = object({
      endpoint    = string
      bucket      = string
      region      = string
      cluster_uid = string
      api_server  = string
    })
  })
  default   = null
  sensitive = true
  validation {
    condition = var.publication_access == null ? true : try(
      can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.publication_access.address)) &&
      can(regex("^[a-z][a-z0-9-]*$", var.publication_access.auth_mount)) &&
      var.publication_access.role_name == "kubernetes-${var.publication_access.publication.cluster_uid}-kubeconfig" &&
      var.publication_access.reader_policy == "${var.publication_access.role_name}-read" &&
      can(regex("^[A-Za-z0-9-]+$", var.publication_access.role_id)) &&
      can(regex("^[a-z][a-z0-9-]*/data/[A-Za-z0-9_/-]+$", var.publication_access.secret_path)) &&
      !contains(["sys", "auth", "identity", "cubbyhole"], split("/", var.publication_access.secret_path)[0]) &&
      alltrue([for part in split("/", var.publication_access.secret_path) : part != ""]) &&
      can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.publication_access.publication.endpoint)) &&
      can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.publication_access.publication.bucket)) &&
      can(regex("^[a-z0-9-]+$", var.publication_access.publication.region)) &&
      can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.publication_access.publication.cluster_uid)) &&
      var.publication_access.publication.api_server == "https://${var.api_dns.name}:6443",
    false)
    error_message = "Supply the unchanged artifacts-root enrollment export for this cluster and the infrastructure's stable API identity; never supply credential values."
  }
}

variable "publication_ssh_known_hosts_file" {
  description = "Operator-owned independently verified guest host-key/CA file, required for publication enrollment."
  type        = string
  default     = null
  sensitive   = true
  validation {
    condition     = var.publication_access == null || var.publication_ssh_known_hosts_file != null
    error_message = "Publication enrollment requires a verified guest known-hosts file."
  }
}

variable "publication_issuer_token" {
  description = "Ephemeral, wrapped-SecretID issuer credential only; it has no S3 or application-secret read permission."
  type        = string
  default     = null
  sensitive   = true
  ephemeral   = true
}

variable "publication_enrollment_revision" {
  description = "Explicit enrollment retry trigger; does not install assets, replace the VM or rotate an existing SecretID."
  type        = string
  default     = "1"
  nullable    = false
}

locals {
  publication_enabled = nonsensitive(var.publication_access != null)
  publication_assets = {
    "/usr/local/libexec/homelab/publish-kubeconfig.py" = { source = "scripts/publish-kubeconfig.py", mode = "0700" }
    "/usr/local/sbin/kubeconfig-credentials"           = { source = "scripts/kubeconfig-credentials.sh", mode = "0700" }
    "/etc/systemd/system/kubernetes-publication-credentials.service" = {
      source = "config/kubernetes-publication-credentials.service", mode = "0644"
    }
    "/etc/systemd/system/kubernetes-publication-credentials.timer" = {
      source = "config/kubernetes-publication-credentials.timer", mode = "0644"
    }
    "/etc/systemd/system/kubernetes-kubeconfig-publication.service" = {
      source = "config/kubernetes-kubeconfig-publication.service", mode = "0644"
    }
  }
  publication_openbao = local.publication_enabled ? {
    address       = var.publication_access.address
    auth_mount    = var.publication_access.auth_mount
    role_name     = var.publication_access.role_name
    role_id       = var.publication_access.role_id
    reader_policy = var.publication_access.reader_policy
    secret_path   = var.publication_access.secret_path
    implementation_sha256 = sha256(join("", concat([
      for destination in sort(keys(local.publication_assets)) : filesha256("${path.module}/${local.publication_assets[destination].source}")
    ], [filesha256("${path.module}/scripts/kubernetes_object_store.py")])))
  } : null
  publication_target = local.publication_enabled ? merge(var.publication_access.publication, {
    initializer        = true
    rke2_config_sha256 = sha256(local.rke2_config)
  }) : null
  publication_files = concat([
    for destination, asset in local.publication_assets : {
      path = destination, mode = asset.mode, content = file("${path.module}/${asset.source}")
    }
    ], [
    { path = "/etc/tmpfiles.d/kubernetes-publication.conf", mode = "0644", content = "d /run/kubernetes-publication-credentials 0700 root root - -\n" }
  ])
  publication_config_sha256 = sha256(jsonencode({ openbao = local.publication_openbao, publication = local.publication_target }))
}

output "publication_host_configuration" {
  description = "Protected non-secret host metadata for a separately approved in-place installation; never credentials."
  sensitive   = true
  value = local.publication_enabled ? {
    openbao       = local.publication_openbao
    publication   = local.publication_target
    config_sha256 = local.publication_config_sha256
  } : null
}

resource "terraform_data" "publication_enrollment" {
  count = local.publication_enabled ? 1 : 0

  triggers_replace = [
    local.publication_config_sha256,
    filesha256(pathexpand(var.publication_ssh_known_hosts_file)),
    var.publication_enrollment_revision,
  ]

  depends_on = [proxmox_virtual_environment_vm.control_plane, technitium_record.api]
  lifecycle {
    replace_triggered_by = [proxmox_virtual_environment_vm.control_plane]
  }

  provisioner "local-exec" {
    command = "bash \"${path.module}/scripts/enroll-control-plane.sh\""
    environment = {
      BAO_ADDR                  = var.publication_access.address
      BAO_AUTH_MOUNT            = var.publication_access.auth_mount
      BAO_TOKEN                 = var.publication_issuer_token == null ? "" : var.publication_issuer_token
      PUBLICATION_ROLE          = var.publication_access.role_name
      CONTROL_PLANE_SSH_TARGET  = "${var.cloud_user}@${local.primary_ipv4}"
      CONTROL_PLANE_KNOWN_HOSTS = pathexpand(var.publication_ssh_known_hosts_file)
      PUBLICATION_CONFIG_SHA256 = local.publication_config_sha256
      PUBLICATION_CONFIGURATION = jsonencode({ openbao = local.publication_openbao, publication = local.publication_target })
    }
  }
}
