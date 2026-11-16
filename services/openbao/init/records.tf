provider "technitium" {
  server_url      = var.technitium_server_url
  skip_tls_verify = false
}

resource "technitium_record" "openbao" {
  zone      = var.dns_zone
  name      = var.dns_name
  type      = "A"
  value     = incus_instance.openbao.ipv4_address
  ttl       = var.dns_ttl
  overwrite = false

  lifecycle {
    precondition {
      condition     = can(cidrnetmask("${incus_instance.openbao.ipv4_address}/32"))
      error_message = "Incus must report a usable IPv4 address before registering DNS."
    }
  }
}
