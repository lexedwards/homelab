locals {
  bootstrap_assets = {
    "/usr/local/libexec/homelab/kubernetes_object_store.py"       = { source = "../scripts/bootstrap/kubernetes_object_store.py", mode = "0644" }
    "/usr/local/libexec/homelab/kubernetes_recovery.py"           = { source = "../scripts/bootstrap/kubernetes_recovery.py", mode = "0644" }
    "/usr/local/libexec/homelab/rke2-bootstrap.py"                = { source = "../scripts/bootstrap/rke2-bootstrap.py", mode = "0700" }
    "/usr/local/libexec/homelab/complete-bootstrap.py"            = { source = "../scripts/bootstrap/complete-bootstrap.py", mode = "0700" }
    "/usr/local/libexec/homelab/prepare-recovery.py"              = { source = "../scripts/bootstrap/prepare-recovery.py", mode = "0700" }
    "/usr/local/libexec/homelab/backup-recovery-custody.py"       = { source = "../scripts/bootstrap/backup-recovery-custody.py", mode = "0700" }
    "/usr/local/libexec/homelab/install-enrollment.py"            = { source = "../scripts/bootstrap/install-enrollment.py", mode = "0700" }
    "/usr/local/libexec/homelab/publish-kubeconfig.py"            = { source = "../scripts/bootstrap/publish-kubeconfig.py", mode = "0700" }
    "/usr/local/sbin/bootstrap-credentials"                       = { source = "../scripts/bootstrap/bootstrap-credentials.sh", mode = "0700" }
    "/etc/systemd/system/kubernetes-bootstrap.service"            = { source = "config/kubernetes-bootstrap.service", mode = "0644" }
    "/etc/systemd/system/kubernetes-bootstrap.timer"              = { source = "config/kubernetes-bootstrap.timer", mode = "0644" }
    "/etc/systemd/system/rke2-server.service.d/20-bootstrap.conf" = { source = "config/rke2-bootstrap.conf", mode = "0644" }
  }
  bootstrap_files = concat([
    for destination, asset in local.bootstrap_assets : {
      path = destination, mode = asset.mode, content = file("${path.module}/${asset.source}")
    }
    ], [
    { path = "/etc/tmpfiles.d/kubernetes-bootstrap.conf", mode = "0644", content = "d /run/kubernetes-bootstrap 0700 root root - -\nd /var/lib/kubernetes-bootstrap 0700 root root - -\n" }
  ])
}
