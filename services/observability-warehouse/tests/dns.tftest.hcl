mock_provider "proxmox" {
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "snippets:snippets/test.yaml" }
  }
}
mock_provider "technitium" {}

variables {
  proxmox_endpoint             = "https://proxmox.example.invalid"
  proxmox_api_token            = "synthetic-test-token"
  proxmox_ssh_username         = "test@pam"
  proxmox_ssh_private_key_file = "tests/dns.tftest.hcl"
  proxmox_nodes = {
    compute = { ssh_address = "compute.example.invalid", snippet_datastore_id = "snippets", vm_datastore_id = "vms", vm_bridge = "br0" }
    store   = { ssh_address = "store.example.invalid", snippet_datastore_id = "snippets", vm_datastore_id = "vms", vm_bridge = "br0" }
  }
  warehouse_vm_id       = 100
  collector_vm_id       = 101
  grafana_vm_id         = 102
  template_vm_id        = 103
  template_node_name    = "store"
  cloud_user            = "test"
  cloud_ssh_public_keys = ["synthetic-test-key"]
  nfs_server            = "backup.example.invalid"
  nfs_export            = "/backups"
  s3_endpoint           = "storage.example.invalid:9000"
  technitium_server_url = "https://dns.example.invalid"
  technitium_records = {
    collector = {
      zone     = "example.invalid"
      name     = "collector.example.invalid"
      type     = "A"
      value    = "192.0.2.20"
      ttl      = 91
      comments = "Collector"
    }
    grafana_alias = {
      zone  = "example.invalid"
      name  = "grafana.example.invalid"
      type  = "CNAME"
      value = "proxy.example.invalid"
      ttl   = 37
    }
  }
}

run "manage_service_records_with_explicit_proxy_target" {
  command = plan

  plan_options {
    target = [technitium_record.managed]
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
    error_message = "Service records must use explicit inputs, preserve the proxy-routed Grafana target, and disable recordset overwrite."
  }
}

run "reject_direct_grafana_address_record" {
  command = plan

  plan_options {
    target = [technitium_record.managed]
  }

  variables {
    technitium_records = {
      grafana_alias = {
        zone  = "example.invalid"
        name  = "grafana.example.invalid"
        type  = "A"
        value = "192.0.2.30"
        ttl   = 60
      }
    }
  }

  expect_failures = [var.technitium_records]
}

run "reject_unrelated_record_ownership" {
  command = plan

  plan_options {
    target = [technitium_record.managed]
  }

  variables {
    technitium_records = {
      unrelated = {
        zone  = "example.invalid"
        name  = "unrelated.example.invalid"
        type  = "A"
        value = "192.0.2.30"
        ttl   = 60
      }
    }
  }

  expect_failures = [var.technitium_records]
}

run "reject_colliding_service_names" {
  command = plan

  plan_options {
    target = [technitium_record.managed]
  }

  variables {
    technitium_records = {
      collector = {
        zone  = "example.invalid"
        name  = "same.example.invalid"
        type  = "A"
        value = "192.0.2.20"
        ttl   = 60
      }
      grafana_alias = {
        zone  = "example.invalid"
        name  = "SAME.EXAMPLE.INVALID."
        type  = "CNAME"
        value = "proxy.example.invalid"
        ttl   = 60
      }
    }
  }

  expect_failures = [var.technitium_records]
}

run "explicit_empty_map_owns_no_records" {
  command = plan

  plan_options {
    target = [technitium_record.managed]
  }

  variables {
    technitium_records = {}
  }

  assert {
    condition     = length(technitium_record.managed) == 0
    error_message = "An explicitly empty map must not adopt or create any record."
  }
}
