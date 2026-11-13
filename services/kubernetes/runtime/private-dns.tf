variable "private_dns_forwarding" {
  description = "Optional exact private DNS suffix and existing internal IPv4 resolver. Adds native CoreDNS conditional forwarding without replacing cluster/public DNS configuration. Requires the enabled API runtime inputs."
  type = object({
    zone     = string
    resolver = string
  })
  sensitive = true
  default   = null

  validation {
    condition = var.private_dns_forwarding == null ? true : (
      var.secrets_platform != null &&
      length(var.private_dns_forwarding.zone) <= 253 &&
      length(split(".", var.private_dns_forwarding.zone)) >= 2 &&
      alltrue([for label in split(".", var.private_dns_forwarding.zone) : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", label))]) &&
      var.private_dns_forwarding.zone != "cluster.local" && !endswith(var.private_dns_forwarding.zone, ".cluster.local") &&
      can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.private_dns_forwarding.resolver)) &&
      try(cidrhost("${var.private_dns_forwarding.resolver}/32", 0) == var.private_dns_forwarding.resolver, false)
    )
    error_message = "Private DNS routing requires enabled runtime inputs, an exact lowercase DNS suffix outside cluster.local and one valid IPv4 resolver without directives, ports or whitespace."
  }
}

resource "kubernetes_manifest" "private_dns_forwarding" {
  count = nonsensitive(var.private_dns_forwarding != null) ? 1 : 0
  manifest = {
    apiVersion = "helm.cattle.io/v1"
    kind       = "HelmChartConfig"
    metadata   = { name = "rke2-coredns", namespace = "kube-system" }
    spec = {
      valuesContent = yamlencode({
        extraConfig = { import = { parameters = "/etc/coredns/private-forward.server" } }
        zoneFiles = [{
          filename = "private-forward.server"
          contents = "${var.private_dns_forwarding.zone}:53 {\n    errors\n    cache 30\n    forward . ${var.private_dns_forwarding.resolver}\n}\n"
        }]
      })
    }
  }
  lifecycle { prevent_destroy = true }
}
