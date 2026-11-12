locals {
  service_pools = var.service_exposure == null ? {} : var.service_exposure.pools
  service_pool_numbers = { for name, pool in local.service_pools : name => {
    start = try(sum([for i, octet in split(".", pool.start) : tonumber(octet) * pow(256, 3 - i)]), 0)
    stop  = try(sum([for i, octet in split(".", pool.stop) : tonumber(octet) * pow(256, 3 - i)]), 0)
  } }
  service_exposure_values = merge(
    var.service_exposure == null ? {} : { l2announcements = { enabled = true } },
    var.service_exposure == null ? {} : { devices = sort(tolist(var.service_exposure.devices)) },
    var.service_exposure == null ? {} : { k8sClientRateLimit = { qps = 50, burst = 100 } },
  )
  service_pool_files = { for name, pool in local.service_pools : "pool-${name}.yaml" => yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumLoadBalancerIPPool"
    metadata   = { name = "service-${name}" }
    spec = {
      blocks = [{ start = pool.start, stop = pool.stop }]
      serviceSelector = { matchLabels = {
        "homelab.io/service-pool" = name
      } }
    }
  }) }
  service_announcement_files = { for name, pool in local.service_pools : "announcement-${name}.yaml" => yamlencode({
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumL2AnnouncementPolicy"
    metadata   = { name = "service-${name}" }
    spec = {
      serviceSelector = { matchLabels = {
        "homelab.io/service-pool" = name
      } }
      nodeSelector    = { matchLabels = { "homelab.io/role" = "worker" } }
      interfaces      = ["^${pool.interface}$"]
      externalIPs     = false
      loadBalancerIPs = true
    }
  }) }
}

output "service_exposure_manifests" {
  description = "Private YAML files to export to a protected directory and review before separately authorized native reconciliation. Not an automatic Kubernetes apply."
  sensitive   = true
  value = merge(local.service_pool_files, local.service_announcement_files,
    var.service_exposure == null ? {} : { "rke2-cilium-config.yaml" = local.cilium_config }
  )
  precondition {
    condition = alltrue([for name, range in local.service_pool_numbers :
      range.start <= range.stop && alltrue([for other, peer in local.service_pool_numbers :
        name == other || range.stop < peer.start || peer.stop < range.start
      ])
    ])
    error_message = "Service ranges must be ordered and must not overlap any other service pool."
  }
  precondition {
    condition = alltrue([for name, pool in local.service_pools : try(alltrue([
      for network in [var.cluster_networks.pods, var.cluster_networks.services] :
      !cidrcontains(network, pool.start) && !cidrcontains(network, pool.stop) && !cidrcontains(pool.subnet, cidrhost(network, 0))
    ]), false)])
    error_message = "Service pool subnets must not overlap the internal Pod or Service networks."
  }
}
