locals {
  management_address = split("/", var.management_address_cidr)[0]
  management_prefix  = split("/", var.management_address_cidr)[1]
  management_subnet  = "${cidrhost(var.management_address_cidr, 0)}/${local.management_prefix}"

  cloud_init_seed = {
    "meta-data" = "instance-id: ${jsonencode(var.instance_id)}\n"
    "network-config" = templatefile("${path.module}/cloud-init/network-config.tftpl", {
      dns_servers             = var.dns_servers
      gateway_ipv4            = var.gateway_ipv4
      management_address_cidr = var.management_address_cidr
      management_vlan_id      = var.management_vlan_id
      parent_interface        = var.parent_interface
    })
    "user-data" = templatefile("${path.module}/cloud-init/user-data.tftpl", {
      admin_authorized_keys = var.admin_authorized_keys
      admin_username        = var.admin_username
      hostname_prefix       = var.hostname_prefix
      management_address    = local.management_address
      management_subnet     = local.management_subnet
      management_vlan_id    = var.management_vlan_id
      parent_interface      = var.parent_interface
    })
  }
}

resource "local_sensitive_file" "cloud_init_seed" {
  for_each = toset(["meta-data", "network-config", "user-data"])

  content              = local.cloud_init_seed[each.key]
  filename             = "${path.module}/cloud-init/rendered/${each.key}"
  file_permission      = "0600"
  directory_permission = "0700"
}
