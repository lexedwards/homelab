#!/usr/bin/env bash
set -euo pipefail
[[ $(getenforce) == Enforcing ]] || { echo 'SELinux is not enforcing.' >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo 'An amd64 server is required.' >&2; exit 1; }
[[ $(swapon --noheadings --show | wc -l) -eq 0 ]] || { echo 'Swap must be disabled.' >&2; exit 1; }
ip -j -4 address show | python3 -c '
import ipaddress, json, pathlib, sys
expected = ipaddress.IPv4Address(pathlib.Path("/etc/kubernetes-node-address").read_text().strip())
actual = {a["local"] for link in json.load(sys.stdin) for a in link.get("addr_info", []) if a.get("family") == "inet"}
if str(expected) not in actual:
    raise SystemExit("Reserved node address is not assigned; verify DHCP/MAC before starting RKE2.")
'
