#!/usr/bin/env python3
"""Bootstrap from the primary DHCP lease; require the same identity on restart."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


def primary_identity(routes, interfaces):
    devices = {route['dev'] for route in routes if 'dev' in route}
    if len(devices) != 1:
        raise ValueError('Exactly one default-route interface is required for bootstrap.')
    matches = [link for link in interfaces if link['ifname'] in devices]
    if len(matches) != 1:
        raise ValueError('The default-route interface is missing or ambiguous.')
    link = matches[0]
    addresses = [a['local'] for a in link.get('addr_info', []) if a.get('family') == 'inet' and a.get('scope') == 'global']
    if len(addresses) != 1:
        raise ValueError('The primary interface must have exactly one global-scope IPv4 lease.')
    address = ipaddress.IPv4Address(addresses[0])
    mac = link.get('address', '').lower()
    if address.is_loopback or address.is_link_local or address.is_multicast or address.is_unspecified:
        raise ValueError('The primary lease is not a usable node address.')
    if not re.fullmatch(r'[0-9a-f][02468ace](:[0-9a-f]{2}){5}', mac) or mac == '00:00:00:00:00:00':
        raise ValueError('The primary NIC must have a nonzero unicast MAC.')
    return {'ipv4_address': str(address), 'mac_address': mac}


def check_identity(expected, interfaces):
    matches = [link for link in interfaces if link.get('address', '').lower() == expected['mac_address'].lower()]
    if len(matches) != 1 or not any(a.get('family') == 'inet' and a.get('scope') == 'global' and a.get('local') == expected['ipv4_address'] for a in matches[0].get('addr_info', [])):
        raise ValueError('The bootstrap IP/MAC pair changed; restore the DHCP reservation before starting RKE2.')


def write_json(path, value):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(value, stream, indent=2)
            stream.write('\n')
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def configure(rke2_path, cilium_path, identity_path, identity, expected):
    for key in ['ipv4_address', 'mac_address']:
        supplied = expected.get(key)
        if supplied is not None and supplied.lower() != identity[key].lower():
            raise ValueError('The DHCP lease does not match the optional pre-existing reservation.')
    rke2 = json.loads(rke2_path.read_text())
    for key in ['cluster-cidr', 'service-cidr']:
        if ipaddress.IPv4Address(identity['ipv4_address']) in ipaddress.IPv4Network(rke2[key]):
            raise ValueError('The primary address overlaps an internal cluster network.')
    cilium = json.loads(cilium_path.read_text())
    values = json.loads(cilium['spec']['valuesContent'])
    rke2['node-ip'] = identity['ipv4_address']
    values['k8sServiceHost'] = identity['ipv4_address']
    cilium['spec']['valuesContent'] = json.dumps(values)
    write_json(rke2_path, rke2)
    write_json(cilium_path, cilium)
    write_json(identity_path, identity)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        interfaces = json.loads(subprocess.check_output(['ip', '-j', '-4', 'address', 'show'], text=True, timeout=10))
        identity_path = Path('/etc/kubernetes-node-identity.json')
        if args.check:
            check_identity(json.loads(identity_path.read_text()), interfaces)
        else:
            if Path('/var/lib/rancher/rke2/server/db/etcd').exists():
                raise ValueError('Bootstrap configuration must not rewrite an existing datastore identity.')
            routes = json.loads(subprocess.check_output(['ip', '-j', '-4', 'route', 'show', 'default'], text=True, timeout=10))
            configure(Path('/etc/rancher/rke2/config.yaml'), Path('/var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml'), identity_path, primary_identity(routes, interfaces), json.loads(Path('/etc/kubernetes-bootstrap-identity.json').read_text()))
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        message = str(error) if type(error) is ValueError else 'Unable to read or configure the primary node identity; inspect protected guest inputs.'
        raise SystemExit(message) from None


if __name__ == '__main__':
    main()
