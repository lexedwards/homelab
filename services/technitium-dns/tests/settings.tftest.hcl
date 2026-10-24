mock_provider "incus" {
  mock_data "incus_storage_pool" {
    defaults = { driver = "dir" }
  }

  mock_data "incus_network" {
    defaults = { type = "bridge", managed = false }
  }
}

mock_provider "technitium" {}

variables {
  technitium_records    = {}
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

run "manage_static_records_without_clobbering_siblings" {
  command = plan

  variables {
    technitium_records = {
      administration = {
        zone      = "example.invalid"
        name      = "dns.example.invalid"
        type      = "CNAME"
        value     = "host.example.invalid"
        ttl       = 47
        comments  = "Administration"
        ownership = "dns_administration"
      }
      legacy_address = {
        zone      = "example.invalid"
        name      = "host.example.invalid"
        type      = "A"
        value     = "192.0.2.10"
        ttl       = 123
        ownership = "legacy_compute_store"
      }
      legacy_pointer = {
        zone      = "2.0.192.in-addr.arpa"
        name      = "10.2.0.192.in-addr.arpa"
        type      = "PTR"
        value     = "host.example.invalid"
        ttl       = 0
        comments  = ""
        ownership = "legacy_compute_store"
      }
    }
  }

  assert {
    condition = nonsensitive(alltrue([
      for label, record in var.technitium_records :
      technitium_record.managed[label].zone == record.zone &&
      technitium_record.managed[label].name == record.name &&
      technitium_record.managed[label].type == record.type &&
      technitium_record.managed[label].value == record.value &&
      technitium_record.managed[label].ttl == record.ttl &&
      (try(record.comments, null) == null ? true : technitium_record.managed[label].comments == record.comments) &&
      technitium_record.managed[label].overwrite == false
    ]))
    error_message = "Records must retain private identities, explicit TTLs and comments without recordset overwrite."
  }
}

run "reject_duplicate_record_identity" {
  command = plan

  variables {
    technitium_records = {
      first = {
        zone      = "example.invalid"
        name      = "alias.example.invalid"
        type      = "CNAME"
        value     = "proxy.example.invalid"
        ttl       = 60
        ownership = "legacy_untracked_service"
      }
      second = {
        zone      = "EXAMPLE.INVALID."
        name      = "ALIAS.EXAMPLE.INVALID."
        type      = "CNAME"
        value     = "PROXY.EXAMPLE.INVALID."
        ttl       = 60
        ownership = "legacy_untracked_service"
      }
    }
  }

  expect_failures = [var.technitium_records]
}

run "allow_distinct_sibling_values_without_overwrite" {
  command = plan

  variables {
    technitium_records = {
      first = {
        zone      = "example.invalid"
        name      = "host.example.invalid"
        type      = "A"
        value     = "192.0.2.10"
        ttl       = 60
        ownership = "legacy_compute_store"
      }
      second = {
        zone      = "example.invalid"
        name      = "host.example.invalid"
        type      = "A"
        value     = "192.0.2.11"
        ttl       = 60
        ownership = "legacy_compute_store"
      }
    }
  }

  assert {
    condition     = length(technitium_record.managed) == 2 && alltrue([for record in technitium_record.managed : record.overwrite == false])
    error_message = "Distinct sibling values must be independently addressable without enabling overwrite."
  }
}

run "reject_conflicting_sibling_ttls" {
  command = plan

  variables {
    technitium_records = {
      first = {
        zone      = "example.invalid"
        name      = "host.example.invalid"
        type      = "A"
        value     = "192.0.2.10"
        ttl       = 60
        ownership = "legacy_compute_store"
      }
      second = {
        zone      = "example.invalid"
        name      = "host.example.invalid"
        type      = "A"
        value     = "192.0.2.11"
        ttl       = 61
        ownership = "legacy_compute_store"
      }
    }
  }

  expect_failures = [var.technitium_records]
}

run "reject_unrepresented_record_type" {
  command = plan

  variables {
    technitium_records = {
      apex = {
        zone      = "example.invalid"
        name      = "example.invalid"
        type      = "NS"
        value     = "ns.example.invalid"
        ttl       = 60
        ownership = "dns_administration"
      }
    }
  }

  expect_failures = [var.technitium_records]
}

run "reject_missing_ttl" {
  command = plan

  variables {
    technitium_records = {
      invalid = {
        zone      = "example.invalid"
        name      = "host.example.invalid"
        type      = "A"
        value     = "192.0.2.10"
        ttl       = null
        ownership = "legacy_compute_store"
      }
    }
  }

  expect_failures = [var.technitium_records]
}

run "reject_unclassified_ownership" {
  command = plan

  variables {
    technitium_records = {
      invalid = {
        zone      = "example.invalid"
        name      = "host.example.invalid"
        type      = "A"
        value     = "192.0.2.10"
        ttl       = 60
        ownership = "unknown"
      }
    }
  }

  expect_failures = [var.technitium_records]
}

run "reject_cname_conflicting_with_address" {
  command = plan

  variables {
    technitium_records = {
      alias = {
        zone      = "example.invalid"
        name      = "host.example.invalid"
        type      = "CNAME"
        value     = "proxy.example.invalid"
        ttl       = 60
        ownership = "legacy_untracked_service"
      }
      address = {
        zone      = "example.invalid"
        name      = "HOST.EXAMPLE.INVALID."
        type      = "A"
        value     = "192.0.2.10"
        ttl       = 60
        ownership = "legacy_compute_store"
      }
    }
  }

  expect_failures = [var.technitium_records]
}

run "reject_outside_zone_record" {
  command = plan

  variables {
    technitium_records = {
      invalid = {
        zone      = "example.invalid"
        name      = "host.other.invalid"
        type      = "A"
        value     = "192.0.2.10"
        ttl       = 60
        ownership = "legacy_compute_store"
      }
    }
  }

  expect_failures = [var.technitium_records]
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
        for name, value in zone : name => technitium_zone.managed[label][name]
      }) == jsonencode(zone)
    ]))
    error_message = "Every zone must preserve its explicit identity, disabled state, serial mode, query/update policies, and ACLs."
  }

  assert {
    condition = alltrue([
      for zone in technitium_zone.managed :
      zone.dnssec == null && zone.notify == null && zone.allow_transfer == null &&
      zone.zone_transfer_tsig_key_names == null && zone.primary_zone_transfer_tsig_key_name == null
    ])
    error_message = "DNSSEC transitions, transfer/notify settings, and TSIG references must remain outside this adoption slice."
  }
}

run "plan_new_zone_without_preexisting_zone_metadata" {
  command = plan

  variables {
    technitium_zones = {
      new_zone = {
        name                       = "new-zone.example.invalid"
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

  assert {
    condition = (
      technitium_zone.managed["new_zone"].name == "new-zone.example.invalid" &&
      technitium_zone.managed["new_zone"].type == "Primary"
    )
    error_message = "Declaring a new zone must plan its managed resource without requiring that zone to exist first."
  }
}

run "reject_unsupported_declared_zone_types" {
  command = plan

  variables {
    technitium_zones = {
      zone_0 = {
        name                       = "example.invalid"
        type                       = "Secondary"
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
