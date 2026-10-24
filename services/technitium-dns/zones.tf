locals {
  technitium_zone_keys = nonsensitive(toset(keys(var.technitium_zones)))
}

data "technitium_zone" "existing" {
  for_each = local.technitium_zone_keys

  name = var.technitium_zones[each.key].name
}

resource "technitium_zone" "existing" {
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

    precondition {
      condition     = data.technitium_zone.existing[each.key].type == "Primary"
      error_message = "Only existing Primary zones have been verified for adoption. Stop for compatibility review of other types."
    }

    precondition {
      condition     = data.technitium_zone.existing[each.key].dnssec_status == "Unsigned"
      error_message = "Only unsigned zones have been verified for adoption. Signing, unsigning, and key changes are not authorized."
    }

    precondition {
      condition = (
        data.technitium_zone.existing[each.key].notify == "ZoneNameServers" &&
        data.technitium_zone.existing[each.key].zone_transfer == "AllowOnlyZoneNameServers"
      )
      error_message = "Only the audited zone-name-server notify/transfer modes have been verified. Preserve other modes outside this adoption path rather than approximate them."
    }
  }
}
