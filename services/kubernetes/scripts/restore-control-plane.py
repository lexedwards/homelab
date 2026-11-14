#!/usr/bin/env python3
import argparse
import base64
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit
import uuid


def require(condition, message):
    if not condition:
        raise ValueError(message)


def private_bytes(path, limit=65536):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as source:
        info = os.fstat(source.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and
                not stat.S_IMODE(info.st_mode) & 0o077, 'Input must be an owned private regular file')
        data = source.read(limit + 1)
        require(0 < len(data) <= limit, 'Input exceeds the approved size bound')
        return data


def validate_target(target):
    fields = {'proxmox_endpoint', 'node', 'vm_id', 'vm_name', 'production_vm_ids', 'template_vm_id',
              'bridge', 'vlan_id', 'cluster_uid', 'cluster_cidr', 'service_cidr', 'scratch_address',
              'snapshot_sha256', 'snapshot_timestamp', 'server_token_hash', 'namespace_uids', 'server_ca_sha256'}
    require(isinstance(target, dict) and set(target) == fields, 'Unexpected restore-target fields')
    endpoint = urlsplit(target['proxmox_endpoint'])
    require(endpoint.scheme == 'https' and endpoint.hostname and not endpoint.username and not endpoint.password and
            endpoint.path in ['', '/'] and not endpoint.query and not endpoint.fragment, 'Verified API origin required')
    require(target['node'] in ['compute', 'store'] and
            re.fullmatch(r'k8s-restore-[a-z0-9-]+', target['vm_name']), 'Explicit scratch identity required')
    require(type(target['vm_id']) is int and target['vm_id'] >= 100 and
            isinstance(target['production_vm_ids'], list) and target['production_vm_ids'] and
            all(type(value) is int and value >= 100 for value in target['production_vm_ids']) and
            type(target['template_vm_id']) is int and target['vm_id'] not in target['production_vm_ids'] and
            target['vm_id'] != target['template_vm_id'], 'Production or template VM cannot be a restore target')
    require(re.fullmatch(r'[a-zA-Z0-9_.-]+', target['bridge']) and type(target['vlan_id']) is int and
            1 <= target['vlan_id'] <= 4094, 'Invalid expected bootstrap network')
    require(str(uuid.UUID(target['cluster_uid'])) == target['cluster_uid'], 'Invalid cluster UID')
    for field in ['cluster_cidr', 'service_cidr']:
        network = ipaddress.ip_network(target[field])
        require(network.version == 4 and network.is_private, 'Expected private IPv4 cluster networks')
    address = ipaddress.ip_address(target['scratch_address'])
    require(address in ipaddress.ip_network('192.0.2.0/24'), 'Use a documentation-only isolated guest address')
    require(all(re.fullmatch(r'[0-9a-f]{64}', target[key]) for key in ['snapshot_sha256', 'server_ca_sha256']) and
            re.fullmatch(r'[0-9a-f]{12}', target['server_token_hash']), 'Missing recovery-point associations')
    require(type(target['snapshot_timestamp']) is int and 0 < target['snapshot_timestamp'] <= time.time(),
            'Invalid snapshot timestamp')
    require(isinstance(target['namespace_uids'], dict) and target['namespace_uids'].get('kube-system') == target['cluster_uid'] and
            all(re.fullmatch(r'[a-z0-9-]+', key) and str(uuid.UUID(value)) == value
                for key, value in target['namespace_uids'].items()), 'Invalid expected namespace identities')
    return target


def verify_fence(target, vm):
    require(isinstance(vm, dict) and isinstance(vm.get('tags'), str) and isinstance(vm.get('net0'), str) and
            vm.get('name') == target['vm_name'] and vm.get('template', 0) == 0 and
            {'iac', 'kubernetes-restore-lab'} <= set(vm.get('tags', '').split(';')), 'Refuse an unowned VM')
    require({key for key in vm if re.fullmatch(r'net[0-9]+', key)} == {'net0'}, 'Exactly one fenced NIC required')
    require(not vm.get('args') and not any(re.fullmatch(r'(?:hostpci|usb)[0-9]+', key) for key in vm),
            'Unreviewed passthrough or QEMU arguments invalidate the network fence')
    parts = vm['net0'].split(',')
    require(all('=' in value for value in parts), 'Invalid NIC configuration')
    options = dict(value.split('=', 1) for value in parts)
    require(len(options) == len(parts) and options.get('link_down') == '1' and
            options.get('bridge') == target['bridge'] and options.get('tag') == str(target['vlan_id']),
            'Hypervisor NIC is not fenced as reviewed')


class API:
    def __init__(self, target, token):
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args):
                raise ValueError('API redirect refused')
        require(re.fullmatch(r'[^\s@]+@[^\s!]+![^\s=]+=\S+', token), 'Expected a complete Proxmox API credential')
        self.target = target
        self.token = token
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect)
        self.path = '/nodes/' + target['node'] + '/qemu/' + str(target['vm_id'])

    def call(self, path, payload=None):
        request = urllib.request.Request(self.target['proxmox_endpoint'].rstrip('/') + '/api2/json' + path,
            data=json.dumps(payload).encode() if payload is not None else None,
            headers={'Authorization': 'PVEAPIToken=' + self.token, 'Content-Type': 'application/json'})
        try:
            with self.opener.open(request, timeout=30) as response:
                return json.load(response)['data']
        except urllib.error.HTTPError as error:
            error.close()
            raise ValueError('Proxmox operation failed; details suppressed') from None

    def guard(self):
        verify_fence(self.target, self.call(self.path + '/config?current=1'))
        require(self.call(self.path + '/status/current')['status'] == 'running', 'Scratch VM must be running')

    def require_exec_capability(self):
        document = self.call(self.path + '/agent/info')
        document = document.get('result', document)
        commands = document.get('supported_commands', document.get('supported-commands', []))
        enabled = {item.get('name') for item in commands if item.get('enabled') is True}
        require({'guest-exec', 'guest-exec-status'} <= enabled,
                'Scratch guest agent must explicitly permit execution and status before restoration')

    def guest(self, payload, timeout=60):
        self.guard()
        data = json.dumps(payload)
        require(len(data.encode()) <= 65536, 'Guest-agent stdin bound exceeded')
        result = self.call(self.path + '/agent/exec', {
            'command': ['/usr/libexec/qemu-ga/fsfreeze-hook.d/homelab-restore'], 'input-data': data})
        require(type(result.get('pid')) is int, 'No guest operation identity')
        pid = result['pid']
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = self.call(self.path + '/agent/exec-status?pid=' + str(pid))
            if result.get('exited'):
                require(result.get('exitcode') == 0 and not result.get('out-truncated'), 'Guest operation failed; output suppressed')
                result = json.loads(result.get('out-data', ''))
                require(result.get('successful') is True, 'Guest check failed; details suppressed')
                return result
            time.sleep(0.25)
        raise ValueError('Guest operation timed out; preserve fenced scratch VM for inspection')


GUEST = (Path(__file__).resolve().parents[1] / 'restore-lab/guest-restore.py').read_text()


def execute(target, snapshot, server_token, api):
    spec = importlib.util.spec_from_file_location('etcd_backup', Path(__file__).with_name('etcd-backup.py'))
    backup = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(backup)
    require(hashlib.sha256(snapshot).hexdigest() == target['snapshot_sha256'] and
            backup.server_token_hash(server_token) == target['server_token_hash'], 'Recovery material does not match the selected point')
    started = time.monotonic()
    api.require_exec_capability()
    api.guest({'operation': 'probe', 'vm_name': target['vm_name']}, timeout=120)
    api.guest({'operation': 'prepare', 'scratch_address': target['scratch_address']})
    for offset in range(0, len(snapshot), 32768):
        api.guest({'operation': 'append', 'offset': offset, 'data': base64.b64encode(snapshot[offset:offset + 32768]).decode()})
    api.guest({'operation': 'configure', 'target': target, 'server_token': server_token})
    api.guest({'operation': 'reset'}, timeout=660)
    api.guest({'operation': 'start'})
    deadline = time.monotonic() + 900
    while time.monotonic() < deadline:
        try:
            result = api.guest({'operation': 'verify', 'target': target}, timeout=120)
            api.guard()
            result.update(observed_restore_seconds=round(time.monotonic() - started, 1),
                          duration_excludes_lab_provisioning_and_snapshot_download=True,
                          recovery_point_age_seconds=int(time.time() - target['snapshot_timestamp']),
                          hypervisor_fence_verified=True, scratch_production_network_access_disabled=True,
                          scratch_cleanup_required=True)
            return result
        except (ValueError, urllib.error.URLError):
            time.sleep(5)
    raise ValueError('Isolated API/datastore recovery not verified within bound')


def main():
    parser = argparse.ArgumentParser(description='Plan or explicitly restore only an owned, hardware-fenced scratch VM through its guest agent.')
    parser.add_argument('--config', required=True)
    parser.add_argument('--snapshot-file', required=True)
    parser.add_argument('--server-token-file', required=True)
    parser.add_argument('--proxmox-token-file', required=True)
    parser.add_argument('--receipt')
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        target = validate_target(json.loads(private_bytes(args.config)))
        if not args.execute:
            print(json.dumps({'plan_only': True, 'no_credential_snapshot_access_or_live_operations': True}))
            return
        require(args.receipt is not None, 'Explicit private receipt destination required')
        receipt = Path(args.receipt)
        require(not receipt.exists() and not receipt.is_symlink(), 'Receipt collision')
        require(not any(path.is_symlink() for path in receipt.parents), 'Receipt parent symlink')
        info = receipt.parent.stat()
        require(info.st_uid == os.geteuid() and not stat.S_IMODE(info.st_mode) & 0o077,
                'Receipt parent must be private and operator-owned')
        descriptor = os.open(str(receipt) + '.started', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.close(descriptor)
        token = private_bytes(args.proxmox_token_file).decode().strip()
        api = API(target, token)
        api.guard()
        snapshot = private_bytes(args.snapshot_file, 64 * 1024 * 1024)
        require(Path(args.server_token_file).resolve() != Path('/var/lib/rancher/rke2/server/token'), 'Use independent custody material, not the live server token')
        server_token = private_bytes(args.server_token_file).decode().strip()
        try:
            result = execute(target, snapshot, server_token, api)
        except Exception:
            result = {'successful': False, 'preserve_fenced_scratch_for_inspection': True, 'do_not_retry_blindly': True}
            raise
        finally:
            if 'result' in locals():
                descriptor = os.open(receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(descriptor, 'w') as output:
                    json.dump(result, output)
        print('Isolated restore verified. Scratch remains fenced; inspect receipt and separately review cleanup.')
    except Exception:
        parser.exit(1, 'Isolated restore stopped; details suppressed. Preserve the scratch VM and inspect the reviewed procedure.\n')


if __name__ == '__main__':
    main()
