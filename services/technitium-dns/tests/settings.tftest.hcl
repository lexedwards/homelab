mock_provider "incus" {
  mock_data "incus_storage_pool" {
    defaults = { driver = "dir" }
  }

  mock_data "incus_network" {
    defaults = { type = "bridge", managed = false }
  }
}

mock_provider "technitium" {
  mock_data "technitium_zone" {
    defaults = {
      type          = "Primary"
      dnssec_status = "Unsigned"
      notify        = "ZoneNameServers"
      zone_transfer = "AllowOnlyZoneNameServers"
    }
  }
}

variables {
  incus_remote          = "test-remote"
  instance_vlan_id      = 100
  technitium_server_url = "https://dns.example.invalid"
  technitium_zones = {
    zone_0 = {
      name                       = "example.invalid"
      type                       = "Primary"
      disabled                   = false
      soa_serial_date_scheme     = false
      query_access               = "UseSpecifiedNetworkACL"
      query_access_network_acl   = ["192.0.2.0/24"]
      dynamic_update             = "Deny"
      dynamic_update_network_acl = []
    }
    zone_1 = {
      name                       = "2.0.192.in-addr.arpa"
      type                       = "Primary"
      disabled                   = true
      soa_serial_date_scheme     = true
      query_access               = "Allow"
      query_access_network_acl   = []
      dynamic_update             = "UseSpecifiedNetworkACL"
      dynamic_update_network_acl = ["192.0.2.1/32"]
    }
  }
  technitium_settings = {
    allow_txt_blocking_report        = false
    block_list_update_interval_hours = 12
    block_list_urls                  = ["https://example.invalid/blocklist.txt"]
    blocking_answer_ttl              = 60
    blocking_bypass_list             = ["192.0.2.0/24"]
    blocking_type                    = "AnyAddress"
    cache_maximum_record_ttl         = 86400
    cache_minimum_record_ttl         = 0
    custom_blocking_addresses        = []
    dnssec_validation                = false
    enable_blocking                  = false
    enable_dns_over_https            = false
    enable_dns_over_tls              = false
    forwarder_protocol               = "Udp"
    forwarders                       = ["192.0.2.53"]
    log_queries                      = false
    logging_type                     = "None"
    max_log_file_days                = 7
    notify_allowed_networks          = []
    qname_minimization               = false
    randomize_name                   = false
    recursion                        = "UseSpecifiedNetworkACL"
    recursion_network_acl            = ["192.0.2.0/24"]
    serve_stale                      = false
    udp_payload_size                 = 1400
    zone_transfer_allowed_networks   = []
  }
}

run "preserve_explicit_settings_instead_of_provider_defaults" {
  command = plan

  assert {
    condition = nonsensitive(jsonencode({
      for name, value in var.technitium_settings : name => technitium_server_settings.existing[name]
    }) == jsonencode(var.technitium_settings))
    error_message = "Every adopted setting must retain its explicit operator value, including false, zero, and empty lists."
  }

  assert {
    condition = alltrue([
      technitium_server_settings.existing.web_service_local_addresses == null,
      technitium_server_settings.existing.web_service_http_port == null,
      technitium_server_settings.existing.web_service_enable_tls == null,
      technitium_server_settings.existing.web_service_http_to_tls_redirect == null,
      technitium_server_settings.existing.web_service_use_self_signed_tls_certificate == null,
      technitium_server_settings.existing.web_service_tls_port == null,
      technitium_server_settings.existing.web_service_tls_certificate_path == null,
      technitium_server_settings.existing.web_service_tls_certificate_password == null,
    ])
    error_message = "Web listeners and certificate configuration must remain operator-managed."
  }
}

run "reject_null_settings_that_would_restore_provider_defaults" {
  command = plan

  variables {
    technitium_settings = {
      allow_txt_blocking_report        = false
      block_list_update_interval_hours = 12
      block_list_urls                  = []
      blocking_answer_ttl              = 60
      blocking_bypass_list             = []
      blocking_type                    = "AnyAddress"
      cache_maximum_record_ttl         = 86400
      cache_minimum_record_ttl         = 0
      custom_blocking_addresses        = []
      dnssec_validation                = null
      enable_blocking                  = false
      enable_dns_over_https            = false
      enable_dns_over_tls              = false
      forwarder_protocol               = "Udp"
      forwarders                       = null
      log_queries                      = false
      logging_type                     = "None"
      max_log_file_days                = 7
      notify_allowed_networks          = []
      qname_minimization               = false
      randomize_name                   = false
      recursion                        = "UseSpecifiedNetworkACL"
      recursion_network_acl            = ["192.0.2.0/24"]
      serve_stale                      = false
      udp_payload_size                 = 1400
      zone_transfer_allowed_networks   = []
    }
  }

  expect_failures = [var.technitium_settings]
}

run "reject_non_http_api_endpoints" {
  command = plan

  variables {
    technitium_server_url = "file:///not-an-api"
  }

  expect_failures = [var.technitium_server_url]
}

run "preserve_existing_guest_interface_name" {
  command = plan

  assert {
    condition = one([
      for device in incus_instance.technitium_dns.device : try(device.properties["name"], null)
      if device.name == "eth0"
    ]) == "eth0"
    error_message = "The imported guest interface name must remain explicitly configured, not removed on apply."
  }
}

run "preserve_explicit_zone_properties_without_adopting_excluded_policies" {
  command = plan

  assert {
    condition = nonsensitive(alltrue([
      for label, zone in var.technitium_zones : jsonencode({
        for name, value in zone : name => technitium_zone.existing[label][name]
      }) == jsonencode(zone)
    ]))
    error_message = "Every zone must preserve its explicit identity, disabled state, serial mode, query/update policies, and ACLs."
  }

  assert {
    condition = alltrue([
      for zone in technitium_zone.existing :
      zone.dnssec == null && zone.notify == null && zone.allow_transfer == null &&
      zone.zone_transfer_tsig_key_names == null && zone.primary_zone_transfer_tsig_key_name == null
    ])
    error_message = "DNSSEC transitions, transfer/notify settings, and TSIG references must remain outside this adoption slice."
  }
}

run "reject_signed_zone_adoption_before_any_write" {
  command = plan

  override_data {
    target = data.technitium_zone.existing["zone_0"]
    values = {
      type          = "Primary"
      dnssec_status = "SignedWithNSEC"
      notify        = "ZoneNameServers"
      zone_transfer = "AllowOnlyZoneNameServers"
    }
  }

  expect_failures = [technitium_zone.existing]
}

run "reject_untested_live_zone_types" {
  command = plan

  override_data {
    target = data.technitium_zone.existing["zone_0"]
    values = {
      type          = "Secondary"
      dnssec_status = "Unsigned"
      notify        = "ZoneNameServers"
      zone_transfer = "AllowOnlyZoneNameServers"
    }
  }

  expect_failures = [technitium_zone.existing]
}

run "reject_lossy_combined_transfer_and_notify_modes" {
  command = plan

  override_data {
    target = data.technitium_zone.existing["zone_0"]
    values = {
      type          = "Primary"
      dnssec_status = "Unsigned"
      notify        = "BothZoneAndSpecifiedNameServers"
      zone_transfer = "AllowZoneNameServersAndUseSpecifiedNetworkACL"
    }
  }

  expect_failures = [technitium_zone.existing]
}

run "reject_null_zone_policy_inputs" {
  command = plan

  variables {
    technitium_zones = {
      zone_0 = {
        name                       = "example.invalid"
        type                       = "Primary"
        disabled                   = false
        soa_serial_date_scheme     = false
        query_access               = null
        query_access_network_acl   = []
        dynamic_update             = "Deny"
        dynamic_update_network_acl = []
      }
    }
  }

  expect_failures = [var.technitium_zones]
}

run "reject_multiple_owners_of_the_same_zone" {
  command = plan

  variables {
    technitium_zones = {
      zone_0 = {
        name                       = "example.invalid"
        type                       = "Primary"
        disabled                   = false
        soa_serial_date_scheme     = false
        query_access               = "Allow"
        query_access_network_acl   = []
        dynamic_update             = "Deny"
        dynamic_update_network_acl = []
      }
      zone_1 = {
        name                       = "EXAMPLE.INVALID."
        type                       = "Primary"
        disabled                   = false
        soa_serial_date_scheme     = false
        query_access               = "Allow"
        query_access_network_acl   = []
        dynamic_update             = "Deny"
        dynamic_update_network_acl = []
      }
    }
  }

  expect_failures = [var.technitium_zones]
}
