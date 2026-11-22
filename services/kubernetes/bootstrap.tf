variable "cluster_bootstrap" {
  description = "Explicit empty-datastore lifecycle. Default existing mode refuses initialization; values contain authorization/selection metadata only, never tokens or S3 credentials."
  type = object({
    mode      = optional(string, "existing")
    node_name = optional(string)
    access = optional(object({
      address           = string
      auth_mount        = string
      role_name         = string
      role_id           = string
      reader_policy     = string
      s3_secret_path    = optional(string)
      server_token_path = optional(string)
    }))
    backup = optional(object({
      endpoint = string
      bucket   = string
      region   = string
    }))
    recovery_point = optional(object({
      cluster_uid  = string
      key          = string
      sha256       = string
      size         = number
      token_hash   = string
      source_node  = string
      timestamp    = number
      rke2_version = string
      api_server   = string
    }))
    join_server                   = optional(string)
    fencing_confirmed             = optional(bool, false)
    independent_custody_confirmed = optional(bool, false)
  })
  default   = {}
  nullable  = false
  sensitive = true
  validation {
    condition = contains(["existing", "create", "join", "restore"], var.cluster_bootstrap.mode) && (
      var.cluster_bootstrap.node_name == null ? true : can(regex("^[a-z0-9][a-z0-9-]{0,62}$", var.cluster_bootstrap.node_name))
    )
    error_message = "Select existing, create, join or restore and an optional explicit valid replacement Node name."
  }
  validation {
    condition = var.cluster_bootstrap.mode == "existing" ? true : try(
      can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.cluster_bootstrap.access.address)) &&
      can(regex("^[a-z][a-z0-9-]*$", var.cluster_bootstrap.access.auth_mount)) &&
      can(regex("^kubernetes-[a-z0-9-]+-bootstrap$", var.cluster_bootstrap.access.role_name)) &&
      can(regex("^[A-Za-z0-9-]+$", var.cluster_bootstrap.access.role_id)) &&
      var.cluster_bootstrap.access.reader_policy == "${var.cluster_bootstrap.access.role_name}-read" &&
      alltrue([for path in compact([var.cluster_bootstrap.access.s3_secret_path, var.cluster_bootstrap.access.server_token_path]) :
        can(regex("^[a-z][a-z0-9-]*/data/[A-Za-z0-9_/-]+$", path)) &&
        !contains(["sys", "auth", "identity", "cubbyhole"], split("/", path)[0]) && alltrue([for part in split("/", path) : part != ""])
      ]) &&
      (var.cluster_bootstrap.mode == "join" ? var.cluster_bootstrap.access.s3_secret_path == null : var.cluster_bootstrap.access.s3_secret_path != null) &&
      (var.cluster_bootstrap.mode == "create" ? var.cluster_bootstrap.access.server_token_path == null : can(regex("/server-token/[0-9a-f]{12}$", var.cluster_bootstrap.access.server_token_path))) &&
    (var.cluster_bootstrap.access.s3_secret_path == null ? true : !strcontains(var.cluster_bootstrap.access.s3_secret_path, "/server-token/")), false)
    error_message = "Supply the recovery root's exact enrollment export with S3 access only for create/restore and token access only for join/restore."
  }
  validation {
    condition = contains(["create", "restore"], var.cluster_bootstrap.mode) ? try(
      can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.cluster_bootstrap.backup.endpoint)) &&
      can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.cluster_bootstrap.backup.bucket)) &&
    can(regex("^[a-z0-9-]+$", var.cluster_bootstrap.backup.region)), false) : var.cluster_bootstrap.backup == null
    error_message = "Create/restore requires the published existing backup target; join/existing must not select backup storage."
  }
  validation {
    condition     = var.cluster_bootstrap.mode == "join" ? can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", var.cluster_bootstrap.join_server)) : var.cluster_bootstrap.join_server == null
    error_message = "Only join mode may configure an existing verified-HTTPS registration endpoint."
  }
  validation {
    condition = var.cluster_bootstrap.mode == "restore" ? try(
      var.cluster_bootstrap.fencing_confirmed && var.cluster_bootstrap.independent_custody_confirmed &&
      var.cluster_bootstrap.node_name != null && var.cluster_bootstrap.node_name != var.cluster_bootstrap.recovery_point.source_node &&
      can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.cluster_bootstrap.recovery_point.cluster_uid)) &&
      can(regex("^[a-z0-9][a-z0-9-]{0,62}$", var.cluster_bootstrap.recovery_point.source_node)) &&
      can(regex("^[0-9a-f]{64}$", var.cluster_bootstrap.recovery_point.sha256)) &&
      can(regex("^[0-9a-f]{12}$", var.cluster_bootstrap.recovery_point.token_hash)) &&
      floor(var.cluster_bootstrap.recovery_point.size) == var.cluster_bootstrap.recovery_point.size &&
      var.cluster_bootstrap.recovery_point.size > 0 && var.cluster_bootstrap.recovery_point.size <= 17179869184 &&
      floor(var.cluster_bootstrap.recovery_point.timestamp) == var.cluster_bootstrap.recovery_point.timestamp &&
      var.cluster_bootstrap.recovery_point.timestamp > 0 &&
      contains([
        "rke2/${var.cluster_bootstrap.recovery_point.cluster_uid}/homelab-scheduled-${var.cluster_bootstrap.recovery_point.source_node}-${var.cluster_bootstrap.recovery_point.timestamp}",
        "rke2/${var.cluster_bootstrap.recovery_point.cluster_uid}/homelab-scheduled-${var.cluster_bootstrap.recovery_point.source_node}-${var.cluster_bootstrap.recovery_point.timestamp}.zip"
      ], var.cluster_bootstrap.recovery_point.key) &&
      var.cluster_bootstrap.recovery_point.rke2_version == "v1.36.6+rke2r1" && var.rke2_version == "1.36.6~rke2r1-0.el10" &&
      var.cluster_bootstrap.recovery_point.api_server == "https://${var.api_dns.name}:6443" &&
    endswith(var.cluster_bootstrap.access.server_token_path, "/server-token/${var.cluster_bootstrap.recovery_point.token_hash}"), false) : var.cluster_bootstrap.recovery_point == null
    error_message = "Restore requires an exact qualified recovery-point export, preserved stable API/version, matching token-record suffix, distinct replacement Node, independent custody and explicit fencing."
  }
  validation {
    condition = var.publication_access == null ? true : (
      !contains(["create", "restore"], var.cluster_bootstrap.mode) ? true : try(
        var.cluster_bootstrap.backup.bucket != var.publication_access.publication.bucket &&
      (var.cluster_bootstrap.mode == "restore" ? var.cluster_bootstrap.recovery_point.cluster_uid == var.publication_access.publication.cluster_uid : true), false)
    )
    error_message = "Publication must use a different bucket and, during restoration, the same selected cluster UID."
  }
}

variable "bootstrap_ssh_known_hosts_file" {
  description = "Independently verified guest host-key/CA file for bootstrap introduction; required outside existing mode."
  type        = string
  default     = null
  sensitive   = true
  validation {
    condition     = var.cluster_bootstrap.mode == "existing" || var.bootstrap_ssh_known_hosts_file != null
    error_message = "Bootstrap introduction needs an independently verified guest known-hosts file."
  }
}

variable "bootstrap_issuer_token" {
  description = "Ephemeral exact-role wrapped-SecretID issuer only; not an OpenBao administrator or application credential."
  type        = string
  default     = null
  sensitive   = true
  ephemeral   = true
}

variable "bootstrap_enrollment_revision" {
  description = "Explicit introduction retry trigger; never reinstalls files, deletes data or replays a reset."
  type        = string
  default     = "1"
  nullable    = false
}

locals {
  server_node_name = coalesce(var.cluster_bootstrap.node_name, var.control_plane.name)
  bootstrap_enroll = nonsensitive(var.cluster_bootstrap.mode != "existing")
  bootstrap_metadata = {
    mode                          = var.cluster_bootstrap.mode
    configuration_sha256          = sha256(local.rke2_config)
    node_name                     = local.server_node_name
    backup                        = var.cluster_bootstrap.backup
    access                        = var.cluster_bootstrap.access
    recovery_point                = var.cluster_bootstrap.recovery_point
    fencing_confirmed             = var.cluster_bootstrap.fencing_confirmed
    independent_custody_confirmed = var.cluster_bootstrap.independent_custody_confirmed
  }
  bootstrap_assets = {
    "/usr/local/libexec/homelab/kubernetes_object_store.py"       = { source = "scripts/kubernetes_object_store.py", mode = "0644" }
    "/usr/local/libexec/homelab/kubernetes_recovery.py"           = { source = "scripts/kubernetes_recovery.py", mode = "0644" }
    "/usr/local/libexec/homelab/rke2-bootstrap.py"                = { source = "scripts/rke2-bootstrap.py", mode = "0700" }
    "/usr/local/sbin/bootstrap-credentials"                       = { source = "scripts/bootstrap-credentials.sh", mode = "0700" }
    "/etc/systemd/system/kubernetes-bootstrap.service"            = { source = "config/kubernetes-bootstrap.service", mode = "0644" }
    "/etc/systemd/system/kubernetes-bootstrap.timer"              = { source = "config/kubernetes-bootstrap.timer", mode = "0644" }
    "/etc/systemd/system/rke2-server.service.d/20-bootstrap.conf" = { source = "config/rke2-bootstrap.conf", mode = "0644" }
  }
  bootstrap_files = concat([
    for destination, asset in local.bootstrap_assets : {
      path = destination, mode = asset.mode, content = file("${path.module}/${asset.source}")
    }
    ], [
    { path = "/etc/rancher/rke2/bootstrap.json", mode = "0600", content = jsonencode(local.bootstrap_metadata) },
    { path = "/etc/tmpfiles.d/kubernetes-bootstrap.conf", mode = "0644", content = "d /run/kubernetes-bootstrap 0700 root root - -\n" }
  ])
  bootstrap_config_sha256 = sha256(jsonencode(local.bootstrap_metadata))
}

output "bootstrap_host_configuration" {
  description = "Protected non-secret bootstrap intent for a separately approved in-place installation."
  sensitive   = true
  value = {
    metadata      = local.bootstrap_metadata
    config_sha256 = local.bootstrap_config_sha256
  }
}

resource "terraform_data" "bootstrap_enrollment" {
  count = local.bootstrap_enroll ? 1 : 0
  triggers_replace = [
    local.bootstrap_config_sha256,
    filesha256(pathexpand(var.bootstrap_ssh_known_hosts_file)),
    var.bootstrap_enrollment_revision,
  ]
  depends_on = [proxmox_virtual_environment_vm.control_plane, technitium_record.api]
  lifecycle {
    replace_triggered_by = [proxmox_virtual_environment_vm.control_plane]
  }
  provisioner "local-exec" {
    command = "bash \"${path.module}/scripts/enroll-control-plane.sh\""
    environment = {
      BAO_ADDR                        = var.cluster_bootstrap.access.address
      BAO_AUTH_MOUNT                  = var.cluster_bootstrap.access.auth_mount
      BAO_TOKEN                       = var.bootstrap_issuer_token == null ? "" : var.bootstrap_issuer_token
      PUBLICATION_ROLE                = var.cluster_bootstrap.access.role_name
      CONTROL_PLANE_CREDENTIAL_HELPER = "bootstrap-credentials"
      CONTROL_PLANE_SSH_TARGET        = "${var.cloud_user}@${local.primary_ipv4}"
      CONTROL_PLANE_KNOWN_HOSTS       = pathexpand(var.bootstrap_ssh_known_hosts_file)
      PUBLICATION_CONFIG_SHA256       = local.bootstrap_config_sha256
    }
  }
}
