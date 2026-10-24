locals {
  technitium_zone_keys = nonsensitive(toset(keys(var.technitium_zones)))
}

resource "technitium_zone" "managed" {
  for_each = local.technitium_zone_keys

  name                   = var.technitium_zones[each.key].name
  type                   = var.technitium_zones[each.key].type
  disabled               = var.technitium_zones[each.key].disabled
  soa_serial_date_scheme = var.technitium_zones[each.key].soa_serial_date_scheme

  query_access               = var.technitium_zones[each.key].query_access
  query_access_network_acl   = var.technitium_zones[each.key].query_access_network_acl
  dynamic_update             = var.technitium_zones[each.key].dynamic_update
  dynamic_update_network_acl = var.technitium_zones[each.key].dynamic_update_network_acl

  lifecycle {
    prevent_destroy = true
  }
}
