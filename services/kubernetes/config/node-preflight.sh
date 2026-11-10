#!/usr/bin/env bash
set -euo pipefail
[[ $(getenforce) == Enforcing ]] || { echo 'SELinux is not enforcing.' >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo 'An amd64 server is required.' >&2; exit 1; }
[[ $(swapon --noheadings --show | wc -l) -eq 0 ]] || { echo 'Swap must be disabled.' >&2; exit 1; }
modprobe overlay
modprobe br_netfilter
modprobe nf_conntrack
sysctl -p /etc/sysctl.d/90-kubernetes.conf
