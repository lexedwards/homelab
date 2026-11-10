#!/usr/bin/env bash
set -euo pipefail
[[ $(getenforce) == Enforcing ]] || { echo 'SELinux is not enforcing.' >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo 'An amd64 server is required.' >&2; exit 1; }
[[ $(swapon --noheadings --show | wc -l) -eq 0 ]] || { echo 'Swap must be disabled.' >&2; exit 1; }
python3 /usr/local/libexec/kubernetes-configure-server.py --check
