#!/usr/bin/env bash
set -euo pipefail
[[ $# == 0 || ( $# == 1 && $1 == --check-modules ) ]] || { echo 'Use no arguments for startup, or --check-modules for an availability check.' >&2; exit 2; }
module_options=()
if [[ $# == 1 ]]; then
  module_options=(--dry-run)
else
  [[ $(getenforce) == Enforcing ]] || { echo 'SELinux is not enforcing.' >&2; exit 1; }
  [[ $(uname -m) == x86_64 ]] || { echo 'An amd64 server is required.' >&2; exit 1; }
  [[ $(swapon --noheadings --show | wc -l) -eq 0 ]] || { echo 'Swap must be disabled.' >&2; exit 1; }
fi
while read -r module || [[ -n $module ]]; do
  [[ -z $module || $module == \#* || $module == \;* ]] && continue
  modprobe "${module_options[@]}" "$module"
done < /etc/modules-load.d/kubernetes.conf
if [[ $# == 0 ]]; then
  sysctl -p /etc/sysctl.d/90-kubernetes.conf
fi
