locals {
  grafana_guest_baseline = {
    manage_etc_hosts = true
    ssh_pwauth       = false
    disable_root     = true
    users = [{
      name                = var.cloud_user
      lock_passwd         = true
      shell               = "/bin/bash"
      ssh_authorized_keys = sort(tolist(var.cloud_ssh_public_keys))
      sudo                = "ALL=(ALL) NOPASSWD:ALL"
    }]
    package_update = true
    apt = {
      preserve_sources_list = true
      sources = {
        grafana = {
          source = "deb [signed-by=$KEY_FILE] https://apt.grafana.com stable main"
          key    = file("${path.module}/config/grafana-signing-key.asc")
        }
      }
    }
  }
  grafana_guest_configs = {
    collector = local.collector_cloud_init_user_data
    grafana   = local.grafana_cloud_init_user_data
  }
}

data "cloudinit_config" "grafana_guest" {
  for_each = toset(["collector", "grafana"])

  gzip          = false
  base64_encode = false

  part {
    filename     = "${each.key}-cloud-config.yaml"
    content_type = "text/cloud-config"
    content      = "#cloud-config\n${yamlencode(merge(local.grafana_guest_baseline, yamldecode(local.grafana_guest_configs[each.key])))}"
  }
}
