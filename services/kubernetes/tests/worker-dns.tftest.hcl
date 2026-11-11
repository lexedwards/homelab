mock_provider "technitium" {}

variables {
  zone             = "example.invalid"
  ttl              = 600
  cluster_networks = { pods = "198.18.0.0/16", services = "198.19.0.0/16" }
  workers = {
    compute = {
      fqdn           = "test-worker-a.nodes.example.invalid"
      primary_mac    = "02:00:00:00:00:AA"
      mac_addresses  = ["02:00:00:00:00:ab", "02:00:00:00:00:aa"]
      ipv4_addresses = [["198.18.1.21"], ["192.0.2.21"]]
    }
    store = {
      fqdn           = "test-worker-b.nodes.example.invalid"
      primary_mac    = "02:00:00:00:00:ba"
      mac_addresses  = ["02:00:00:00:00:ba", "02:00:00:00:00:bb"]
      ipv4_addresses = [["127.0.0.1", "169.254.1.1", "192.0.2.22"], ["198.18.1.22"]]
    }
  }
}

run "publish_worker_addresses_by_primary_mac_not_agent_interface_order" {
  module { source = "./modules/worker-dns" }
  command = plan
  assert {
    condition = nonsensitive(
      technitium_record.worker["compute"].value == "192.0.2.21" &&
      technitium_record.worker["store"].value == "192.0.2.22" &&
      technitium_record.worker["compute"].name == "test-worker-a.nodes.example.invalid" &&
      technitium_record.worker["store"].name == "test-worker-b.nodes.example.invalid" &&
      alltrue([for record in technitium_record.worker :
        record.type == "A" && record.zone == "example.invalid" && record.ttl == 600 && !record.overwrite
      ]) && length(technitium_record.worker_ptr) == 0
    )
    error_message = "Worker A records must use primary MAC-matched leases, never secondary/pod addresses; PTR ownership must be opt-in."
  }
}

run "manage_ptr_only_in_the_supplied_existing_reverse_zone" {
  module { source = "./modules/worker-dns" }
  command = apply
  variables { reverse_zone = "2.0.192.in-addr.arpa" }
  assert {
    condition = nonsensitive(
      technitium_record.worker_ptr["compute"].name == "21.2.0.192.in-addr.arpa" &&
      technitium_record.worker_ptr["store"].name == "22.2.0.192.in-addr.arpa" &&
      technitium_record.worker_ptr["compute"].value == "test-worker-a.nodes.example.invalid" &&
      technitium_record.worker_ptr["store"].value == "test-worker-b.nodes.example.invalid" &&
      alltrue([for record in technitium_record.worker_ptr :
        record.type == "PTR" && record.zone == "2.0.192.in-addr.arpa" && record.ttl == 600 && !record.overwrite
      ])
    )
    error_message = "Each approved PTR must reverse the primary lease and point to its managed worker FQDN."
  }
}

run "reconcile_records_when_a_primary_lease_changes" {
  module { source = "./modules/worker-dns" }
  command = plan
  variables {
    reverse_zone = "2.0.192.in-addr.arpa"
    workers = {
      compute = {
        fqdn           = "test-worker-a.nodes.example.invalid"
        primary_mac    = "02:00:00:00:00:aa"
        mac_addresses  = ["02:00:00:00:00:ab", "02:00:00:00:00:aa"]
        ipv4_addresses = [["198.18.1.21"], ["192.0.2.23"]]
      }
    }
  }
  assert {
    condition = nonsensitive(
      technitium_record.worker["compute"].value == "192.0.2.23" &&
      technitium_record.worker_ptr["compute"].name == "23.2.0.192.in-addr.arpa" &&
      technitium_record.worker_ptr["compute"].value == "test-worker-a.nodes.example.invalid"
    )
    error_message = "After DNS ownership is established, A and PTR plans must follow the new primary lease rather than retaining the old address."
  }
}

run "reject_a_missing_primary_mac_match" {
  module { source = "./modules/worker-dns" }
  command = plan
  variables {
    workers = {
      compute = {
        fqdn           = "test-worker-a.nodes.example.invalid"
        primary_mac    = "02:00:00:00:00:aa"
        mac_addresses  = ["02:00:00:00:00:ab"]
        ipv4_addresses = [["192.0.2.21"]]
      }
    }
  }
  expect_failures = [technitium_record.worker["compute"]]
}

run "reject_ambiguous_primary_addresses" {
  module { source = "./modules/worker-dns" }
  command = plan
  variables {
    workers = {
      compute = {
        fqdn           = "test-worker-a.nodes.example.invalid"
        primary_mac    = "02:00:00:00:00:aa"
        mac_addresses  = ["02:00:00:00:00:aa", "02:00:00:00:00:ab"]
        ipv4_addresses = [["192.0.2.21", "192.0.2.23"], ["198.51.100.21"]]
      }
    }
  }
  expect_failures = [technitium_record.worker["compute"]]
}

run "reject_primary_addresses_inside_cluster_networks" {
  module { source = "./modules/worker-dns" }
  command = plan
  variables {
    workers = {
      compute = {
        fqdn           = "test-worker-a.nodes.example.invalid"
        primary_mac    = "02:00:00:00:00:aa"
        mac_addresses  = ["02:00:00:00:00:aa", "02:00:00:00:00:ab"]
        ipv4_addresses = [["198.19.0.21"], ["192.0.2.21"]]
      }
    }
  }
  expect_failures = [technitium_record.worker["compute"]]
}

run "reject_a_reverse_zone_that_does_not_contain_the_primary_leases" {
  module { source = "./modules/worker-dns" }
  command = plan
  variables { reverse_zone = "100.51.198.in-addr.arpa" }
  expect_failures = [technitium_record.worker_ptr]
}

run "disabled_workers_publish_no_records" {
  module { source = "./modules/worker-dns" }
  command = plan
  variables { workers = {} }
  assert {
    condition     = length(technitium_record.worker) == 0 && length(technitium_record.worker_ptr) == 0
    error_message = "A server-only deployment must not acquire worker DNS ownership."
  }
}
