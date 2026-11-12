mock_provider "proxmox" {
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "snippets:snippets/fixture.yaml" }
  }
}
mock_provider "technitium" {}

variables {
  proxmox_endpoint     = "https://proxmox.example.invalid"
  proxmox_ssh_username = "testadmin"
  proxmox_nodes = {
    compute = { ssh_address = "compute.example.invalid", snippet_datastore_id = "snippets", vm_datastore_id = "vms", vm_bridge = "br-test" }
  }
  template              = { vm_id = 100, node_name = "compute" }
  control_plane         = { vm_id = 101, name = "test-server" }
  primary_vlan_id       = 100
  cloud_user            = "testadmin"
  cloud_ssh_public_keys = ["ssh-ed25519 c3ludGhldGljLWtleQ== test-fixture"]
  technitium_server_url = "https://dns.example.invalid"
  api_dns               = { zone = "example.invalid", name = "api.example.invalid" }
  cluster_networks      = { pods = "198.18.0.0/16", services = "198.19.0.0/16" }
}

run "enable_native_l2_without_changing_the_api_or_kata_socket_path" {
  command = plan
  variables {
    service_exposure = {
      devices = ["test0", "test1"]
      pools = {
        primary = { subnet = "192.0.2.0/24", start = "192.0.2.32", stop = "192.0.2.63", interface = "test0" }
      }
    }
  }
  assert {
    condition = try(
      yamldecode(yamldecode(local.cilium_config).spec.valuesContent).l2announcements.enabled &&
      yamldecode(yamldecode(local.cilium_config).spec.valuesContent).operator.rollOutPods &&
      yamldecode(yamldecode(local.cilium_config).spec.valuesContent).operator.replicas == 1 &&
      yamldecode(yamldecode(local.cilium_config).spec.valuesContent).k8sClientRateLimit.qps == 50 &&
      yamldecode(yamldecode(local.cilium_config).spec.valuesContent).k8sClientRateLimit.burst == 100 &&
      toset(yamldecode(yamldecode(local.cilium_config).spec.valuesContent).devices) == toset(["test0", "test1"]) &&
      yamldecode(yamldecode(local.cilium_config).spec.valuesContent).socketLB.hostNamespaceOnly &&
      yamldecode(yamldecode(local.cilium_config).spec.valuesContent).k8sServiceHost == "api.example.invalid",
      false
    )
    error_message = "Explicit exposure must enable native L2 and reviewed devices without losing verified API or Kata socket settings."
  }
  expect_failures = [technitium_record.api]
}

run "leave_existing_bootstrap_unchanged_without_opt_in" {
  command = plan
  assert {
    condition = (
      length(output.service_exposure_manifests) == 0 &&
      !contains(keys(yamldecode(yamldecode(local.cilium_config).spec.valuesContent)), "devices") &&
      !contains(keys(yamldecode(yamldecode(local.cilium_config).spec.valuesContent)), "l2announcements")
    )
    error_message = "No exposure input must mean no pool files or global Cilium device/L2 changes."
  }
  expect_failures = [technitium_record.api]
}

run "enabling_runtime_exposure_does_not_rewrite_first_boot_cilium" {
  command = plan
  variables {
    service_exposure = {
      devices = ["test0", "test1"]
      pools = {
        primary = { subnet = "192.0.2.0/24", start = "192.0.2.32", stop = "192.0.2.63", interface = "test0" }
      }
    }
  }
  assert {
    condition = base64decode(one([
      for file in yamldecode(local.cloud_init).write_files : file
      if file.path == "/var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml"
      ]).content) == yamlencode({
      apiVersion = "helm.cattle.io/v1"
      kind       = "HelmChartConfig"
      metadata   = { name = "rke2-cilium", namespace = "kube-system" }
      spec = { valuesContent = yamlencode({
        kubeProxyReplacement = true
        k8sServiceHost       = "api.example.invalid"
        k8sServicePort       = 6443
        socketLB             = { enabled = true, hostNamespaceOnly = true }
        routingMode          = "tunnel"
        tunnelProtocol       = "vxlan"
        ipam                 = { mode = "kubernetes" }
        operator             = { replicas = 1 }
      }) }
    })
    error_message = "Runtime L2 inputs must not alter the immutable first-boot snippet or trigger control-plane replacement."
  }
  expect_failures = [technitium_record.api]
}

run "select_each_pool_and_its_exact_worker_interface" {
  command = plan
  variables {
    service_exposure = {
      devices = ["test0", "test1"]
      pools = {
        primary   = { subnet = "192.0.2.0/24", start = "192.0.2.32", stop = "192.0.2.63", interface = "test0" }
        secondary = { subnet = "203.0.113.0/24", start = "203.0.113.32", stop = "203.0.113.63", interface = "test1" }
      }
    }
  }
  assert {
    condition = (
      length(output.service_exposure_manifests) == 5 &&
      yamldecode(output.service_exposure_manifests["pool-primary.yaml"]).spec.blocks == [{ start = "192.0.2.32", stop = "192.0.2.63" }] &&
      yamldecode(output.service_exposure_manifests["pool-secondary.yaml"]).spec.serviceSelector.matchLabels == { "homelab.io/service-pool" = "secondary" } &&
      yamldecode(output.service_exposure_manifests["announcement-primary.yaml"]).spec.interfaces == ["^test0$"] &&
      yamldecode(output.service_exposure_manifests["announcement-secondary.yaml"]).spec.interfaces == ["^test1$"] &&
      yamldecode(output.service_exposure_manifests["announcement-primary.yaml"]).spec.nodeSelector.matchLabels == { "homelab.io/role" = "worker" } &&
      !yamldecode(output.service_exposure_manifests["announcement-primary.yaml"]).spec.externalIPs &&
      yamldecode(output.service_exposure_manifests["announcement-primary.yaml"]).spec.loadBalancerIPs &&
      yamldecode(output.service_exposure_manifests["rke2-cilium-config.yaml"]) == yamldecode(local.cilium_config)
    )
    error_message = "Private outputs must preserve exact ranges and explicitly bind matching Services to the correct worker interface."
  }
  expect_failures = [technitium_record.api]
}

run "reject_overlapping_pool_ranges" {
  command = plan
  variables {
    service_exposure = {
      devices = ["test0"]
      pools = {
        first  = { subnet = "192.0.2.0/24", start = "192.0.2.32", stop = "192.0.2.63", interface = "test0" }
        second = { subnet = "192.0.2.0/24", start = "192.0.2.63", stop = "192.0.2.80", interface = "test0" }
      }
    }
  }
  expect_failures = [technitium_record.api, output.service_exposure_manifests]
}

run "reject_reversed_ranges" {
  command = plan
  variables {
    service_exposure = {
      devices = ["test0"]
      pools = {
        primary = { subnet = "192.0.2.0/24", start = "192.0.2.63", stop = "192.0.2.32", interface = "test0" }
      }
    }
  }
  expect_failures = [technitium_record.api, output.service_exposure_manifests]
}

run "reject_pool_outside_its_subnet" {
  command = plan
  variables {
    service_exposure = {
      devices = ["test0"]
      pools = {
        primary = { subnet = "192.0.2.0/24", start = "192.0.2.32", stop = "203.0.113.63", interface = "test0" }
      }
    }
  }
  expect_failures = [technitium_record.api, var.service_exposure]
}

run "reject_interface_regex_or_missing_device" {
  command = plan
  variables {
    service_exposure = {
      devices = ["test0"]
      pools = {
        primary = { subnet = "192.0.2.0/24", start = "192.0.2.32", stop = "192.0.2.63", interface = "test.*" }
      }
    }
  }
  expect_failures = [technitium_record.api, var.service_exposure]
}

run "reject_internal_network_overlap" {
  command = plan
  variables {
    service_exposure = {
      devices = ["test0"]
      pools = {
        primary = { subnet = "198.18.0.0/24", start = "198.18.0.32", stop = "198.18.0.63", interface = "test0" }
      }
    }
  }
  expect_failures = [technitium_record.api, output.service_exposure_manifests]
}

run "reject_network_and_broadcast_addresses" {
  command = plan
  variables {
    service_exposure = {
      devices = ["test0"]
      pools = {
        primary = { subnet = "192.0.2.0/24", start = "192.0.2.0", stop = "192.0.2.255", interface = "test0" }
      }
    }
  }
  expect_failures = [technitium_record.api, var.service_exposure]
}
