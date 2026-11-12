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

run "render_private_retained_nondefault_storage_without_chown" {
  command = plan
  variables {
    nfs_storage = {
      server             = "nfs.example.invalid"
      share              = "/synthetic/kubernetes"
      storage_class_name = "test-nfs-retain"
      qualification_identity = {
        uid = 1234
        gid = 2345
      }
    }
  }
  assert {
    condition = try(
      yamldecode(output.nfs_manifests["storage-class.yaml"]).reclaimPolicy == "Retain" &&
      yamldecode(output.nfs_manifests["storage-class.yaml"]).parameters.server == "nfs.example.invalid" &&
      yamldecode(output.nfs_manifests["storage-class.yaml"]).parameters.share == "/synthetic/kubernetes" &&
      yamldecode(output.nfs_manifests["storage-class.yaml"]).metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "false" &&
      yamldecode(output.nfs_manifests["storage-class.yaml"]).parameters.onDelete == "retain" &&
      yamldecode(output.nfs_manifests["storage-class.yaml"]).parameters.mountPermissions == "0770" &&
      !contains(keys(yamldecode(output.nfs_manifests["storage-class.yaml"]).parameters), "uid") &&
      !contains(keys(yamldecode(output.nfs_manifests["storage-class.yaml"]).parameters), "gid"),
      false
    )
    error_message = "NFS rendering must preserve private inputs, explicit retained non-default storage and mapped backend ownership without chown."
  }
  expect_failures = [technitium_record.api]
}

run "leave_storage_disabled_without_private_inputs" {
  command = plan
  assert {
    condition     = length(output.nfs_manifests) == 0
    error_message = "No private NFS input must mean no storage or qualification output."
  }
  expect_failures = [technitium_record.api]
}

run "preserve_unique_retained_paths_and_hard_nfs4_mounts" {
  command = plan
  variables {
    nfs_storage = {
      server                 = "nfs.example.invalid"
      share                  = "/synthetic/kubernetes"
      storage_class_name     = "test-nfs-retain"
      qualification_identity = { uid = 1234, gid = 2345 }
    }
  }
  assert {
    condition = (
      yamldecode(output.nfs_manifests["storage-class.yaml"]).parameters.subDir == "$${pvc.metadata.namespace}/$${pvc.metadata.name}/$${pv.metadata.name}" &&
      yamldecode(output.nfs_manifests["storage-class.yaml"]).mountOptions == ["nfsvers=4.1", "hard", "sec=sys"] &&
      !yamldecode(output.nfs_manifests["storage-class.yaml"]).allowVolumeExpansion &&
      yamldecode(output.nfs_manifests["storage-class.yaml"]).volumeBindingMode == "Immediate"
    )
    error_message = "A replacement claim must get a unique PV path; hard NFS4 mounts and honest capacity semantics must remain explicit."
  }
  assert {
    condition = alltrue([
      for document in [for text in split("\n---\n", output.nfs_manifests["qualification.yaml"]) : yamldecode(text)] :
      document.spec.template.spec.securityContext.runAsNonRoot &&
      document.spec.template.spec.securityContext.runAsUser == 1234 &&
      document.spec.template.spec.securityContext.runAsGroup == 2345 &&
      !contains(keys(document.spec.template.spec.securityContext), "fsGroup") &&
      !document.spec.template.spec.automountServiceAccountToken &&
      document.spec.template.spec.topologySpreadConstraints[0].minDomains == 2 &&
      document.spec.template.spec.containers[0].readinessProbe.exec.command == ["test", "-f", "/tmp/ready"] &&
      document.spec.template.spec.volumes[0].persistentVolumeClaim.claimName == "witness" &&
      (document.metadata.name == "isolated" ? document.spec.template.spec.runtimeClassName == "kata-clh-runtime-rs" : !contains(keys(document.spec.template.spec), "runtimeClassName"))
      if document.kind == "Deployment"
    ])
    error_message = "Both ordinary and Kata consumers must span both workers, use distinct supplied non-root IDs without fsGroup chown, and avoid NFS-blocking readiness probes."
  }
  expect_failures = [technitium_record.api]
}

run "reject_root_workload_identity" {
  command = plan
  variables {
    nfs_storage = {
      server                 = "nfs.example.invalid", share = "/synthetic/kubernetes", storage_class_name = "test-nfs-retain"
      qualification_identity = { uid = 0, gid = 2345 }
    }
  }
  expect_failures = [technitium_record.api, var.nfs_storage]
}

run "reject_share_root_or_parent_traversal" {
  command = plan
  variables {
    nfs_storage = {
      server                 = "nfs.example.invalid", share = "/synthetic/../unrelated", storage_class_name = "test-nfs-retain"
      qualification_identity = { uid = 1234, gid = 2345 }
    }
  }
  expect_failures = [technitium_record.api, var.nfs_storage]
}

run "reject_endpoint_urls_or_credentials" {
  command = plan
  variables {
    nfs_storage = {
      server                 = "nfs://user:credential@example.invalid", share = "/synthetic/kubernetes", storage_class_name = "test-nfs-retain"
      qualification_identity = { uid = 1234, gid = 2345 }
    }
  }
  expect_failures = [technitium_record.api, var.nfs_storage]
}
