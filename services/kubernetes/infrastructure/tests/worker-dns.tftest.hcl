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

run "select_primary_ipv4_from_unordered_agent_interfaces" {
  module { source = "../modules/worker-dns" }
  command = plan
  assert {
    condition = nonsensitive(
      technitium_record.worker["compute"].value == "192.0.2.21" &&
      technitium_record.worker["store"].value == "192.0.2.22"
    )
    error_message = "Address selection must match MACs case-insensitively and filter loopback/link-local leases."
  }
}

run "reverse_primary_ipv4_into_ptr_names" {
  module { source = "../modules/worker-dns" }
  command = plan
  variables { reverse_zone = "2.0.192.in-addr.arpa" }
  assert {
    condition = nonsensitive(
      technitium_record.worker_ptr["compute"].name == "21.2.0.192.in-addr.arpa" &&
      technitium_record.worker_ptr["store"].name == "22.2.0.192.in-addr.arpa"
    )
    error_message = "PTR names must reverse the octets of the selected primary IPv4 lease."
  }
}
