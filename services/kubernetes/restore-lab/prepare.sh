#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $EUID == 0 ]]
[[ ! -e /var/lib/rancher/rke2/server/db/etcd ]]
[[ ! -e /run/homelab-restore-fenced ]]
bash /usr/local/sbin/install-kubernetes-server 1.36.6~rke2r1-0.el10 0.24-1.el10
systemctl disable rke2-server
! systemctl is-active --quiet rke2-server
install -d -m 0700 /var/lib/homelab-restore /var/lib/rancher/rke2/agent/images
release=https://github.com/rancher/rke2/releases/download/v1.36.6%2Brke2r1
image=rke2-images-core.linux-amd64.tar.zst
expected=58c153e94944039fc05b8e23de9e8f489df049519e55dd33e5790bf5ae19a217
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 1200 \
  "$release/$image" -o "/var/lib/rancher/rke2/agent/images/$image"
printf '%s  %s\n' "$expected" "/var/lib/rancher/rke2/agent/images/$image" | sha256sum --check --status
[[ $(getenforce) == Enforcing ]]
touch /var/lib/homelab-restore-prepared
