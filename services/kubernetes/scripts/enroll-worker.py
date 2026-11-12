#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
from urllib.parse import urlsplit


SERVER = r'''
import json
import subprocess
import sys

p = json.load(sys.stdin)
k = ['/var/lib/rancher/rke2/bin/kubectl', '--kubeconfig', '/etc/rancher/rke2/rke2.yaml',
     '--server', p['api'], '--insecure-skip-tls-verify=false', '--request-timeout=10s']

def command(args):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=20)

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def ready(item):
    return any(c['type'] == 'Ready' and c['status'] == 'True' for c in item['status'].get('conditions', []))

require(command(k + ['get', '--raw=/readyz']).strip() == 'ok', 'API is not ready')
if p['action'] == 'create':
    print(command(['rke2', 'token', 'create', '--ttl=30m', '--description=worker enrollment ' + p['name']]).strip())
elif p['action'] == 'delete':
    name = 'bootstrap-token-' + p['id']
    query = k + ['-n', 'kube-system', 'get', 'secret', name, '--ignore-not-found', '-o', 'name']
    if command(query).strip():
        command(['rke2', 'token', 'delete', p['id']])
    require(not command(query).strip(), 'Bootstrap token still exists')
    print('{}')
else:
    nodes = json.loads(command(k + ['get', 'nodes', '-o', 'json']))['items']
    servers = [n for n in nodes if 'node-role.kubernetes.io/control-plane' in n['metadata']['labels']]
    require(len(servers) == 1, 'Expected the single established control plane')
    require(servers[0]['status']['nodeInfo']['kubeletVersion'] == p['version'], 'Server version differs from the reviewed enrollment version')
    require(any(t['key'] == 'node-role.kubernetes.io/control-plane' and t['effect'] == 'NoSchedule'
                for t in servers[0]['spec'].get('taints', [])), 'Control-plane taint changed')
    identities = {n['metadata']['name']: n['metadata']['uid'] for n in nodes}
    if p['action'] == 'before':
        require(p['name'] not in identities, 'Reconcile the old worker identity before replacement')
        print(json.dumps(identities))
    else:
        require(all(identities.get(name) == uid for name, uid in p['baseline'].items()), 'Existing node identity changed')
        require(set(identities) <= set(p['baseline']) | {p['name']}, 'Unexpected node joined')
        worker = next((n for n in nodes if n['metadata']['name'] == p['name']), None)
        healthy = False
        if worker is not None:
            labels = worker['metadata']['labels']
            healthy = (worker['status']['nodeInfo']['kubeletVersion'] == p['version']
                       and labels.get('homelab.io/role') == 'worker'
                       and labels.get('topology.kubernetes.io/zone') == p['host']
                       and 'node-role.kubernetes.io/control-plane' not in labels and ready(worker)
                       and [a['address'] for a in worker['status']['addresses'] if a['type'] == 'InternalIP'] == [p['primary_ip']])
            pods = json.loads(command(k + ['-n', 'kube-system', 'get', 'pods', '-l', 'k8s-app=cilium',
                                          '--field-selector', 'spec.nodeName=' + p['name'], '-o', 'json']))['items']
            healthy = healthy and len(pods) == 1 and ready(pods[0])
        print(json.dumps({'ready': healthy}))
'''

WORKER = r'''
import json
import os
from pathlib import Path
import socket
import subprocess
import sys

p = json.load(sys.stdin)

def command(args):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=20,
                                   env=dict(os.environ, LC_ALL='C')).strip()

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

require(os.geteuid() == 0 and socket.gethostname().split('.', 1)[0] == p['name'], 'Unexpected worker identity')
require(command(['getenforce']) == 'Enforcing' and not command(['swapon', '--noheadings', '--show']), 'SELinux/swap prerequisite failed')
require(not Path('/var/lib/rancher/rke2/server/db/etcd').exists(), 'Never enroll an etcd server as a worker')
require(not Path('/var/lib/rancher/rke2/agent/client-kubelet.crt').exists(), 'Worker is already enrolled')
require(Path('/var/lib/kubernetes-agent-installed').read_text().strip() != Path('/proc/sys/kernel/random/boot_id').read_text().strip(), 'Wait for the installed-kernel reboot')
require(command(['rpm', '-q', '--last', 'kernel-core']).splitlines()[0].split()[0] == 'kernel-core-' + command(['uname', '-r']), 'Boot the newly installed kernel')
require(command(['rke2', '--version']).splitlines()[0].split()[2] == p['version'], 'Installed agent version differs')
config = json.loads(Path('/etc/rancher/rke2/config.yaml').read_text())
require(config['node-name'] == p['name'] and config['selinux'] is True, 'Worker configuration differs')
require('homelab.io/role=worker' in config['node-label'] and 'topology.kubernetes.io/zone=' + p['host'] in config['node-label'], 'Worker role/physical-host metadata differs')
require(config['server'] == p['supervisor'] and config['token-file'] == '/etc/rancher/rke2/join-token', 'Enrollment endpoint/path differs')
routes = json.loads(command(['ip', '-j', '-4', 'route', 'show', 'default']))
require(len(routes) == 1 and routes[0]['dev'] == 'ens18', 'Only the primary NIC may provide the default route')
require(not json.loads(command(['ip', '-j', '-6', 'route', 'show', 'default'])), 'Unexpected IPv6 default route')
interfaces = json.loads(command(['ip', '-j', 'address', 'show']))
addresses = {name: [a['local'] for i in interfaces if i['ifname'] == name
                   for a in i['addr_info'] if a['family'] == 'inet' and a['scope'] == 'global']
             for name in ['ens18', 'ens19']}
require(all(len(values) == 1 for values in addresses.values()), 'Both NICs need exactly one DHCP IPv4 address')
for interface in ['ens18', 'ens19']:
    profile = command(['nmcli', '-g', 'GENERAL.CON-UUID', 'device', 'show', interface])
    require(command(['nmcli', '-g', 'ipv4.method', 'connection', 'show', 'uuid', profile]) == 'auto', 'DHCP is required')
    if interface == 'ens19':
        settings = command(['nmcli', '-g', 'ipv4.never-default,ipv4.ignore-auto-dns,ipv4.ignore-auto-routes,ipv6.method', 'connection', 'show', 'uuid', profile]).splitlines()
        require(settings == ['yes', 'yes', 'yes', 'disabled'], 'Secondary NetworkManager profile is not active with the required routing/DNS policy')
token = Path('/etc/rancher/rke2/join-token')
require(not token.exists(), 'Never overwrite an existing enrollment file blindly')
if p['action'] == 'install':
    fd = os.open(token, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(p['token'] + '\n')
        f.flush()
        os.fsync(f.fileno())
    command(['restorecon', str(token)])
    command(['systemctl', 'start', '--no-block', 'rke2-agent'])
print(json.dumps({'primary_ip': addresses['ens18'][0]}))
'''


def bootstrap_id(value):
    match = re.fullmatch(r'K10[0-9a-f]{64}::([a-z0-9]{6})\.[a-z0-9]{16}', value)
    if match is None:
        raise ValueError('A secure native agent bootstrap token is required; server credentials are refused')
    return match.group(1)


def api_endpoint(value):
    url = urlsplit(value)
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.path or url.query or url.fragment or url.port != 6443:
        raise ValueError('Supply the stable verified HTTPS API identity on port 6443')
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description='Enroll one fresh worker using a short-lived token over pinned SSH; never reads the recovery token.')
    parser.add_argument('--server-ssh', required=True)
    parser.add_argument('--worker-ssh', required=True)
    parser.add_argument('--identity-file', required=True, type=Path)
    parser.add_argument('--server-known-hosts', required=True, type=Path)
    parser.add_argument('--worker-known-hosts', required=True, type=Path)
    parser.add_argument('--node-name', required=True)
    parser.add_argument('--host', required=True, choices=['compute', 'store'])
    parser.add_argument('--api-server', required=True, type=api_endpoint)
    parser.add_argument('--expected-version', default='v1.36.6+rke2r1')
    parser.add_argument('--timeout', type=int, default=600)
    args = parser.parse_args(argv)
    if not 30 <= args.timeout <= 900 or not re.fullmatch(r'[a-z][a-z0-9-]{0,61}[a-z0-9]', args.node_name):
        parser.error('Use a valid node name and a timeout from 30 through 900 seconds')
    if any(not re.fullmatch(r'[a-z_][a-z0-9_-]*@[A-Za-z0-9.-]+', value) for value in [args.server_ssh, args.worker_ssh]):
        parser.error('SSH targets must be user@host, without SSH options')
    if any(not p.is_file() for p in [args.identity_file, args.server_known_hosts, args.worker_known_hosts]):
        parser.error('The approved identity and both reviewed host-key files must exist')
    deadline = time.monotonic() + args.timeout

    def call(target, program, payload):
        known = args.server_known_hosts if target == args.server_ssh else args.worker_known_hosts
        ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
               '-o', 'UserKnownHostsFile=' + str(known), '-o', 'ConnectTimeout=10',
               '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2',
               '-i', str(args.identity_file), target, 'sudo -n python3 -c ' + shlex.quote(program)]
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError('Enrollment observation timed out')
        result = subprocess.run(ssh, input=json.dumps(payload), text=True, capture_output=True, timeout=min(60, remaining))
        if result.returncode:
            raise RuntimeError('Remote enrollment step failed; output suppressed to protect credentials. Inspect the node privately before retrying')
        return result.stdout.strip()

    base = {'api': args.api_server, 'name': args.node_name, 'host': args.host,
            'version': args.expected_version,
            'supervisor': args.api_server.rsplit(':', 1)[0] + ':9345'}
    baseline = json.loads(call(args.server_ssh, SERVER, dict(base, action='before')))
    network = json.loads(call(args.worker_ssh, WORKER, dict(base, action='check')))
    token_id = None
    try:
        token = call(args.server_ssh, SERVER, dict(base, action='create'))
        token_id = bootstrap_id(token)
        call(args.worker_ssh, WORKER, dict(base, action='install', token=token))
        while True:
            state = json.loads(call(args.server_ssh, SERVER, dict(base, action='observe', baseline=baseline, primary_ip=network['primary_ip'])))
            if state['ready']:
                break
            time.sleep(min(5, max(0, deadline - time.monotonic())))
    finally:
        if token_id is not None:
            deadline = max(deadline, time.monotonic() + 60)
            try:
                call(args.server_ssh, SERVER, dict(base, action='delete', id=token_id))
            except Exception:
                raise RuntimeError('Could not confirm bootstrap-token revocation; its 30-minute TTL remains the backstop. Inspect the server privately') from None
    print('Worker Ready on its primary address with expected role/version and healthy Cilium; original node identities preserved; bootstrap token revoked')
    print('The root-only worker token file is retained for native restart parsing/CA pinning; runtime and post-revocation reboot qualification remain required')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        print('Enrollment failed; inspect protected node diagnostics before any retry. No credential values are printed.', file=sys.stderr)
        sys.exit(1)
