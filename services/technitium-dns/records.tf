resource "technitium_record" "managed" {
  for_each = nonsensitive(toset(keys(var.technitium_records)))

  zone      = var.technitium_records[each.key].zone
  name      = var.technitium_records[each.key].name
  type      = var.technitium_records[each.key].type
  value     = var.technitium_records[each.key].value
  ttl       = var.technitium_records[each.key].ttl
  comments  = var.technitium_records[each.key].comments
  overwrite = false
}
