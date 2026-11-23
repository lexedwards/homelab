locals {
  node_baseline = yamldecode(templatefile("${path.module}/cloud-init/node-baseline.yaml.tftpl", {
    rke2_minor  = join(".", slice(split(".", var.rke2_version), 0, 2))
    signing_key = file("${path.module}/config/rancher-signing-key.asc")
  }))
  server_config = yamldecode(local.cloud_init)
  worker_configs = {
    for host, config in local.worker_cloud_init : host => yamldecode(config)
  }
  control_plane_cloud_config = "#cloud-config\n${yamlencode(merge(local.node_baseline, local.server_config, {
    packages = concat(local.node_baseline.packages, ["jq", "python3-pyyaml"])
    write_files = concat(local.node_baseline.write_files, local.server_config.write_files, [
      for item in local.bootstrap_files : {
        path        = item.path
        owner       = "root:root"
        permissions = item.mode
        encoding    = "b64"
        content     = base64encode(item.content)
      }
    ])
  }))}"
}

data "cloudinit_config" "control_plane" {
  gzip          = false
  base64_encode = false

  part {
    filename     = "kubernetes-control-plane.yaml"
    content_type = "text/cloud-config"
    content      = local.control_plane_cloud_config
  }
}

output "control_plane_bootstrap_sha256" {
  description = "Fingerprint of the immutable VM installation asset; enrollment and recovery operations must not change it."
  sensitive   = true
  value       = sha256(data.cloudinit_config.control_plane.rendered)
}

data "cloudinit_config" "worker" {
  for_each      = local.worker_hosts
  gzip          = false
  base64_encode = false

  part {
    filename     = "kubernetes-worker.yaml"
    content_type = "text/cloud-config"
    content = "#cloud-config\n${yamlencode(merge(local.node_baseline, local.worker_configs[each.key], {
      packages    = concat(local.node_baseline.packages, local.worker_configs[each.key].packages)
      write_files = concat(local.node_baseline.write_files, local.worker_configs[each.key].write_files)
    }))}"
  }
}
