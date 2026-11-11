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
dnf -y install kernel kernel-core kernel-modules kernel-modules-extra audit policycoreutils-python-utils nfs-utils
install -d -m 0755 /etc/pki/rpm-gpg
key=$(mktemp)
trap 'rm -f "$key"' EXIT
curl --fail --silent --show-error --proto '=https' --tlsv1.2 --retry 3 \
  --connect-timeout 10 --max-time 60 https://rpm.rancher.io/public.key -o "$key"
printf '%s  %s\n' 7d2415f7fc532c365c8874bfad966566daaa0d04a9a5ba14d1db6080a9c12629 "$key" | sha256sum --check --status
install -m 0644 "$key" /etc/pki/rpm-gpg/RPM-GPG-KEY-rancher-rke2
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-rancher-rke2
cat > /etc/yum.repos.d/rancher-rke2.repo <<REPO
[rancher-rke2-common-stable]
name=Rancher RKE2 Common (stable)
baseurl=https://rpm.rancher.io/rke2/stable/common/centos/10/noarch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-rancher-rke2
excludepkgs=rke2*

[rancher-rke2-$minor-stable]
name=Rancher RKE2 $minor (stable)
baseurl=https://rpm.rancher.io/rke2/stable/$minor/centos/10/x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-rancher-rke2
excludepkgs=rke2*
REPO
dnf -y --setopt=rancher-rke2-common-stable.excludepkgs= \
  --setopt="rancher-rke2-$minor-stable.excludepkgs=" \
  install "rke2-agent-$version" "rke2-common-$version" "rke2-selinux-$selinux_version"
[[ $(rpm -q --qf '%{VERSION}-%{RELEASE}' rke2-agent) == "$version" ]]
[[ $(rpm -q --qf '%{VERSION}-%{RELEASE}' rke2-common) == "$version" ]]
[[ $(rpm -q --qf '%{VERSION}-%{RELEASE}' rke2-selinux) == "$selinux_version" ]]
cat > /etc/modules-load.d/kubernetes.conf <<'MODULES'
overlay
br_netfilter
nf_conntrack
MODULES
cat > /etc/sysctl.d/90-kubernetes.conf <<'SYSCTL'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
SYSCTL
swapoff -a
sed -i -E '/^[^#].*[[:space:]]swap[[:space:]]/s/^/# kubernetes: /' /etc/fstab
chmod 0700 /etc/rancher/rke2
chmod 0600 /etc/rancher/rke2/config.yaml
restorecon -RF /etc/rancher/rke2 /var/lib/rancher/rke2 /etc/yum.repos.d/rancher-rke2.repo \
  /etc/pki/rpm-gpg/RPM-GPG-KEY-rancher-rke2 /usr/local/sbin/kubernetes-node-preflight \
  /etc/systemd/system/rke2-agent.service.d /etc/NetworkManager/system-connections/kubernetes-service.nmconnection
nmcli general reload
sshd -t
systemctl reload sshd
systemctl daemon-reload
systemctl enable rke2-agent
[[ $(getenforce) == Enforcing ]]
cat /proc/sys/kernel/random/boot_id > /var/lib/kubernetes-agent-installed
