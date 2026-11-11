mock_provider "incus" {
  mock_data "incus_storage_pool" {
    defaults = { driver = "dir" }
  }
  mock_data "incus_network" {
    defaults = { type = "bridge", managed = false }
  }
  mock_resource "incus_instance" {
    defaults = { ipv4_address = "192.0.2.10" }
  }
}

mock_provider "technitium" {}

variables {
  incus_remote          = "test-remote"
  incus_image           = "images:debian/13/cloud/arm64"
  instance_vlan_id      = 100
  technitium_server_url = "https://dns.example.invalid"
  dns_zone              = "example.invalid"
  dns_name              = "bao.example.invalid"
}

run "persistent_server_with_service_owned_dns" {
  command = plan

  override_resource {
    target = incus_instance.openbao
    values = { ipv4_address = "192.0.2.10" }
  }

  assert {
    condition = (
      incus_instance.openbao.running &&
      incus_instance.openbao.config["boot.autostart"] == "true" &&
      incus_instance.openbao.config["limits.memory"] == "1024MiB" &&
      !contains(keys(incus_instance.openbao.config), "security.privileged") &&
      !contains(keys(incus_instance.openbao.config), "raw.apparmor") &&
      !contains(keys(incus_instance.openbao.config), "raw.lxc")
    )
    error_message = "The server must autostart with bounded resources and no unexplained privilege exceptions."
  }

  assert {
    condition = (
      lookup(incus_instance.openbao.config, "security.nesting", "false") == "true" &&
      incus_instance.openbao.config["limits.memory.swap"] == "false"
    )
    error_message = "Debian 13 on the current Micro Node host requires nesting for systemd startup while guest swapping remains disabled."
  }

  assert {
    condition = one([
      for device in incus_instance.openbao.device : device.properties
      if device.name == "data"
      ]) == tomap({
      path   = "/opt/openbao/data"
      pool   = "default"
      source = "openbao-data"
    })
    error_message = "Server data must use a separate persistent volume at the configured storage path."
  }

  assert {
    condition = (
      technitium_record.openbao.type == "A" &&
      technitium_record.openbao.zone == "example.invalid" &&
      technitium_record.openbao.name == "bao.example.invalid" &&
      technitium_record.openbao.value == "192.0.2.10" &&
      technitium_record.openbao.overwrite == false
    )
    error_message = "The service must register its actual guest address without overwriting sibling records."
  }

  assert {
    condition = (
      strcontains(local.server_config, "storage \"raft\"") &&
      strcontains(local.server_config, "https://bao.example.invalid:8200") &&
      strcontains(local.server_config, "tls_disable = false") &&
      strcontains(local.server_config, "/etc/openbao/tls/current/fullchain.pem") &&
      strcontains(local.server_config, "/etc/openbao/tls/current/privkey.pem") &&
      strcontains(local.user_data, "MemorySwapMax=0") &&
      !strcontains(local.user_data, "operator init") &&
      !strcontains(local.user_data, "operator unseal") &&
      !strcontains(local.user_data, "server -dev")
    )
    error_message = "Provision persistent server mode and swap hardening without automating key-bearing initialization or unseal."
  }

  assert {
    condition = (
      contains(yamldecode(local.user_data).packages, "certbot") &&
      contains(yamldecode(local.user_data).packages, "python3-certbot-dns-cloudflare") &&
      strcontains(local.user_data, "ConditionPathExists=/etc/openbao/tls/current/fullchain.pem") &&
      strcontains(local.user_data, "ConditionPathExists=/etc/openbao/tls/current/privkey.pem") &&
      !strcontains(local.user_data, "dns_cloudflare_api_token") &&
      incus_instance.openbao.exec["00-check-server"].command == tolist(["python3", "/usr/local/lib/openbao/check-ready.py", "--allow-pending-tls"])
    )
    error_message = "Install native ACME tooling without credentials and gate server startup until out-of-band TLS enrollment."
  }

  assert {
    condition = (
      yamldecode(local.user_data).write_files[2].path == "/etc/openbao/openbao.hcl" &&
      yamldecode(local.user_data).write_files[2].content == local.server_config &&
      yamldecode(local.user_data).write_files[1].content == file("${path.module}/scripts/check-ready.py") &&
      yamldecode(local.user_data).runcmd[0][0] == "sh"
    )
    error_message = "Rendered cloud-init must retain configuration and verification scripts without YAML escaping damage."
  }
}

run "reject_dns_outside_zone" {
  command = plan
  variables { dns_name = "bao.other.invalid" }
  expect_failures = [var.dns_name]
}

run "reject_invalid_vlan" {
  command = plan
  variables { instance_vlan_id = 4095 }
  expect_failures = [var.instance_vlan_id]
}

run "reject_managed_bridge" {
  command = plan
  override_data {
    target = data.incus_network.br0
    values = { type = "bridge", managed = true }
  }
  expect_failures = [data.incus_network.br0]
}

run "reject_wrong_storage_driver" {
  command = plan
  override_data {
    target = data.incus_storage_pool.default
    values = { driver = "zfs" }
  }
  expect_failures = [data.incus_storage_pool.default]
}
