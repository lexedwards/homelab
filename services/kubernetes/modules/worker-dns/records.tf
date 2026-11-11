locals {
  worker_hosts = nonsensitive(toset(keys(var.workers)))
  primary_interface_index = {
    for host, worker in var.workers : host => try(one([
      for index, mac in worker.mac_addresses : index if lower(mac) == lower(worker.primary_mac)
    ]), null)
  }
  primary_ipv4 = {
    for host, worker in var.workers : host => local.primary_interface_index[host] == null ? null : try(one([
      for address in worker.ipv4_addresses[local.primary_interface_index[host]] : address
      if can(cidrnetmask("${address}/32")) && address != "0.0.0.0" && !startswith(address, "127.") && !startswith(address, "169.254.")
    ]), null)
  }
  reverse_names = {
    for host, address in local.primary_ipv4 : host => address == null ? null : "${join(".", reverse(split(".", address)))}.in-addr.arpa"
  }
}

resource "technitium_record" "worker" {
  for_each = local.worker_hosts

  zone      = var.zone
  name      = var.workers[each.key].fqdn
  type      = "A"
  value     = local.primary_ipv4[each.key]
  ttl       = var.ttl
  overwrite = false

  lifecycle {
    precondition {
      condition     = local.primary_ipv4[each.key] != null
      error_message = "Each worker's primary MAC must match exactly one usable guest-agent IPv4 lease."
    }
    precondition {
      condition = local.primary_ipv4[each.key] == null ? true : (
        !cidrcontains(var.cluster_networks.pods, local.primary_ipv4[each.key]) &&
        !cidrcontains(var.cluster_networks.services, local.primary_ipv4[each.key])
      )
      error_message = "Worker DNS addresses must not overlap internal pod or Service networks."
    }
    precondition {
      condition     = endswith(var.workers[each.key].fqdn, ".${var.zone}")
      error_message = "Worker FQDNs must be within the existing API DNS zone."
    }
  }
}

resource "technitium_record" "worker_ptr" {
  for_each = nonsensitive(var.reverse_zone == null) ? toset([]) : local.worker_hosts

  zone      = var.reverse_zone
  name      = local.reverse_names[each.key]
  type      = "PTR"
  value     = technitium_record.worker[each.key].name
  ttl       = var.ttl
  overwrite = false

  lifecycle {
    precondition {
      condition     = local.reverse_names[each.key] == null ? false : endswith(local.reverse_names[each.key], ".${var.reverse_zone}")
      error_message = "The approved existing reverse zone must contain each worker's primary reverse name."
    }
  }
}
