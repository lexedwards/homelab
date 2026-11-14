#!/usr/bin/env bash
set -euo pipefail
umask 077
configure_guest_admin() {
  [[ $# == 1 && ( $1 == true || $1 == false ) ]] || return 1
  [[ $(getenforce) == Enforcing ]] || return 1
  if [[ $1 == true ]]; then
    getsebool virt_qemu_ga_run_unconfined >/dev/null || return 1
    setsebool -P virt_qemu_ga_run_unconfined on || return 1
    [[ $(getsebool virt_qemu_ga_run_unconfined) == 'virt_qemu_ga_run_unconfined --> on' ]] || return 1
    systemctl restart qemu-guest-agent || return 1
  fi
  [[ $(getenforce) == Enforcing ]]
}

[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0
[[ $EUID == 0 && $# == 1 ]]
[[ ! -e /var/lib/rancher/rke2/server/db/etcd ]]
[[ ! -e /run/homelab-restore-fenced ]]
bash /usr/local/sbin/install-kubernetes-server 1.36.6~rke2r1-0.el10 0.24-1.el10
systemctl disable rke2-server
! systemctl is-active --quiet rke2-server
configure_guest_admin "$1"
install -d -m 0700 /var/lib/homelab-restore /var/lib/rancher/rke2/agent/images
release=https://github.com/rancher/rke2/releases/download/v1.36.6%2Brke2r1
image=rke2-images-core.linux-amd64.tar.zst
expected=58c153e94944039fc05b8e23de9e8f489df049519e55dd33e5790bf5ae19a217
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 1200 \
  "$release/$image" -o "/var/lib/rancher/rke2/agent/images/$image"
printf '%s  %s\n' "$expected" "/var/lib/rancher/rke2/agent/images/$image" | sha256sum --check --status
[[ $(getenforce) == Enforcing ]]
touch /var/lib/homelab-restore-prepared
