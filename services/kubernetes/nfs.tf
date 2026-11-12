locals {
  nfs_manifests = var.nfs_storage == null ? {} : {
    "storage-class.yaml" = yamlencode({
      apiVersion = "storage.k8s.io/v1"
      kind       = "StorageClass"
      metadata = {
        name        = var.nfs_storage.storage_class_name
        annotations = { "storageclass.kubernetes.io/is-default-class" = "false" }
      }
      provisioner = "nfs.csi.k8s.io"
      parameters = {
        server           = var.nfs_storage.server
        share            = var.nfs_storage.share
        subDir           = "$${pvc.metadata.namespace}/$${pvc.metadata.name}/$${pv.metadata.name}"
        mountPermissions = "0770"
        onDelete         = "retain"
      }
      reclaimPolicy        = "Retain"
      volumeBindingMode    = "Immediate"
      allowVolumeExpansion = false
      mountOptions         = ["nfsvers=4.1", "hard", "sec=sys"]
    })
    "qualification.yaml" = templatefile("${path.module}/examples/nfs-workloads.yaml.tftpl", {
      storage_class_name = var.nfs_storage.storage_class_name
      qualification_uid  = var.nfs_storage.qualification_identity.uid
      qualification_gid  = var.nfs_storage.qualification_identity.gid
    })
  }
}

output "nfs_manifests" {
  description = "Private retained NFS StorageClass and owned qualification manifests. Export and review separately; no VM/bootstrap or Kubernetes deployment side effect."
  sensitive   = true
  value       = local.nfs_manifests
}
