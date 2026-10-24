provider "technitium" {
  server_url      = var.technitium_server_url
  skip_tls_verify = false
}

resource "technitium_server_settings" "existing" {
  dnssec_validation     = var.technitium_settings.dnssec_validation
  recursion             = var.technitium_settings.recursion
  recursion_network_acl = var.technitium_settings.recursion_network_acl
  qname_minimization    = var.technitium_settings.qname_minimization
  randomize_name        = var.technitium_settings.randomize_name

  log_queries       = var.technitium_settings.log_queries
  logging_type      = var.technitium_settings.logging_type
  max_log_file_days = var.technitium_settings.max_log_file_days

  enable_blocking                  = var.technitium_settings.enable_blocking
  allow_txt_blocking_report        = var.technitium_settings.allow_txt_blocking_report
  blocking_bypass_list             = var.technitium_settings.blocking_bypass_list
  blocking_type                    = var.technitium_settings.blocking_type
  blocking_answer_ttl              = var.technitium_settings.blocking_answer_ttl
  custom_blocking_addresses        = var.technitium_settings.custom_blocking_addresses
  block_list_urls                  = var.technitium_settings.block_list_urls
  block_list_update_interval_hours = var.technitium_settings.block_list_update_interval_hours

  serve_stale              = var.technitium_settings.serve_stale
  forwarders               = var.technitium_settings.forwarders
  forwarder_protocol       = var.technitium_settings.forwarder_protocol
  enable_dns_over_tls      = var.technitium_settings.enable_dns_over_tls
  enable_dns_over_https    = var.technitium_settings.enable_dns_over_https
  udp_payload_size         = var.technitium_settings.udp_payload_size
  cache_minimum_record_ttl = var.technitium_settings.cache_minimum_record_ttl
  cache_maximum_record_ttl = var.technitium_settings.cache_maximum_record_ttl

  zone_transfer_allowed_networks = var.technitium_settings.zone_transfer_allowed_networks
  notify_allowed_networks        = var.technitium_settings.notify_allowed_networks

  lifecycle {
    prevent_destroy = true
  }
}
