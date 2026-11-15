#!/usr/bin/env bash
set -euo pipefail
umask 077

[[ $EUID == 0 && $# == 2 ]] || { echo 'Run as root with exact RKE2 and SELinux RPM versions.' >&2; exit 1; }
source /etc/os-release
[[ $ID == rocky && $VERSION_ID == 10* && $(uname -m) == x86_64 ]]
[[ $(getenforce) == Enforcing ]]
[[ ! -d /var/lib/rancher/rke2/server/db/etcd && ! -f /var/lib/rancher/rke2/agent/client-kubelet.crt ]] || {
  echo 'First-boot installation must not reprovision an enrolled node.' >&2; exit 1;
}
rm -f /var/lib/kubernetes-agent-installed
version=$1
selinux_version=$2
[[ $version =~ ^1\.[0-9]+\.[0-9]+~rke2r[0-9]+-[0-9]+\.el10$ ]]
[[ $selinux_version =~ ^[0-9]+\.[0-9]+-[0-9]+\.el10$ ]]
minor=$(cut -d. -f1,2 <<< "$version")
rpm -q kernel kernel-core kernel-modules kernel-modules-extra audit policycoreutils-python-utils nfs-utils >/dev/null
dnf -y --setopt=rancher-rke2-common-stable.excludepkgs= \
  --setopt="rancher-rke2-$minor-stable.excludepkgs=" \
  install "rke2-agent-$version" "rke2-common-$version" "rke2-selinux-$selinux_version"
[[ $(rpm -q --qf '%{VERSION}-%{RELEASE}' rke2-agent) == "$version" ]]
[[ $(rpm -q --qf '%{VERSION}-%{RELEASE}' rke2-common) == "$version" ]]
[[ $(rpm -q --qf '%{VERSION}-%{RELEASE}' rke2-selinux) == "$selinux_version" ]]
swapoff -a
sed -i -E '/^[^#].*[[:space:]]swap[[:space:]]/s/^/# kubernetes: /' /etc/fstab
systemd-tmpfiles --create /etc/tmpfiles.d/kubernetes-rke2.conf
restorecon -RF /etc/rancher/rke2 /var/lib/rancher/rke2 \
  /etc/yum.repos.d/rancher-rke2-common-stable.repo \
  "/etc/yum.repos.d/rancher-rke2-$minor-stable.repo" \
  /etc/pki/rpm-gpg/RPM-GPG-KEY-rancher-rke2 /usr/local/sbin/kubernetes-node-preflight \
  /etc/systemd/system/rke2-agent.service.d /etc/NetworkManager/system-connections/kubernetes-service.nmconnection
nmcli general reload
sshd -t
systemctl reload sshd
systemctl daemon-reload
systemctl enable rke2-agent
[[ $(getenforce) == Enforcing ]]
cat /proc/sys/kernel/random/boot_id > /var/lib/kubernetes-agent-installed
