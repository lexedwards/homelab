#!/usr/bin/python3 -I
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import socket
import stat
import subprocess
import sys
import time


def need(test):
    if not test:
        raise ValueError('Restore boundary failed')


def command(args, timeout=30):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    need(result.returncode == 0)
    return result.stdout.strip()


def private(path):
    need(not any(value.is_symlink() for value in [path, *path.parents]))
    info = path.stat()
    need(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o077)
    return path.read_bytes()


def create(path, data):
    need(not any(value.is_symlink() for value in [path, *path.parents]))
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'wb') as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def run(payload):
    operation = payload['operation']
    need(operation in ['probe', 'prepare', 'append', 'configure', 'reset', 'start', 'verify'])
    need(os.geteuid() == 0 and platform.machine() == 'x86_64')
    need(command(['getenforce']) == 'Enforcing')
    need(command(['getsebool', 'virt_qemu_ga_run_unconfined']) == 'virt_qemu_ga_run_unconfined --> on')
    need(Path('/proc/self/attr/current').read_text().strip().split(':')[2] == 'virt_qemu_ga_unconfined_t')
    need(command(['/usr/bin/rke2', '--version']).startswith('rke2 version v1.36.6+rke2r1 '))
    work = Path('/var/lib/homelab-restore/input')
    if operation == 'probe':
        need(set(payload) == {'operation', 'vm_name'} and re.fullmatch(r'k8s-restore-[a-z0-9-]+', payload['vm_name']))
        need(socket.gethostname() == payload['vm_name'])
        marker = Path('/var/lib/homelab-restore-prepared')
        boot = time.time() - float(Path('/proc/uptime').read_text().split()[0])
        need(marker.is_file() and marker.stat().st_mtime < boot)
        need(command(['rpm', '-q', '--qf', '%{VERSION}-%{RELEASE}', 'rke2-selinux']) == '0.24-1.el10')
        need(command(['systemctl', 'show', 'rke2-server', '--property=ActiveState', '--value']) == 'inactive')
        enabled = subprocess.run(['systemctl', 'is-enabled', 'rke2-server'], capture_output=True, text=True)
        need(enabled.returncode == 1 and enabled.stdout.strip() == 'disabled')
        need(not Path('/var/lib/rancher/rke2/server/db/etcd').exists() and not Path('/run/homelab-restore-fenced').exists())
        need(not work.exists())
        image = Path('/var/lib/rancher/rke2/agent/images/rke2-images-core.linux-amd64.tar.zst')
        with image.open('rb') as source:
            need(hashlib.file_digest(source, 'sha256').hexdigest() == '58c153e94944039fc05b8e23de9e8f489df049519e55dd33e5790bf5ae19a217')
        return {'successful': True, 'selinux_enforcing': True, 'stock_helper_transition_verified': True,
                'kernel_reboot_after_preparation_verified': True, 'service_inactive_disabled': True,
                'no_recovery_data_or_initialized_datastore': True, 'core_images_checksum_verified': True,
                'hostname_verified': True}
    if operation == 'prepare':
        need(Path('/var/lib/homelab-restore-prepared').is_file() and not Path('/var/lib/rancher/rke2/server/db/etcd').exists())
        need(command(['systemctl', 'show', 'rke2-server', '--property=ActiveState', '--value']) == 'inactive')
        need(not work.exists() and not work.is_symlink())
        need(not any(value.is_symlink() for value in work.parents))
        work.mkdir(mode=0o700)
        create(work / 'snapshot.zip', b'')
        for interface in Path('/sys/class/net').iterdir():
            if interface.name != 'lo':
                command(['ip', 'link', 'set', interface.name, 'down'])
        need(json.loads(command(['ip', '-j', 'route', 'show', 'default'])) == [])
        need(json.loads(command(['ip', '-6', '-j', 'route', 'show', 'default'])) == [])
        command(['ip', 'address', 'add', payload['scratch_address'] + '/32', 'dev', 'lo'])
    elif operation == 'append':
        path = work / 'snapshot.zip'
        data = base64.b64decode(payload['data'], validate=True)
        need(len(data) <= 32768 and len(private(path)) == payload['offset'])
        descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
        with os.fdopen(descriptor, 'ab') as output:
            output.write(data)
    elif operation == 'configure':
        target = payload['target']
        need(hashlib.sha256(private(work / 'snapshot.zip')).hexdigest() == target['snapshot_sha256'])
        create(work / 'server-token', payload['server_token'].encode())
        config = {'node-name': target['vm_name'], 'node-ip': target['scratch_address'], 'advertise-address': target['scratch_address'],
                  'cluster-cidr': target['cluster_cidr'], 'service-cidr': target['service_cidr'], 'cni': 'none', 'selinux': True,
                  'disable-scheduler': True, 'disable-cloud-controller': True, 'disable-kube-proxy': True, 'etcd-disable-snapshots': True,
                  'etcd-s3': False, 'write-kubeconfig-mode': '0600', 'token-file': str(work / 'server-token'),
                  'node-taint': ['node-role.kubernetes.io/control-plane:NoSchedule'],
                  'disable': ['rke2-coredns', 'rke2-metrics-server', 'rke2-snapshot-controller', 'rke2-snapshot-controller-crd', 'rke2-snapshot-validation-webhook']}
        path = Path('/etc/rancher/rke2/config.yaml')
        private(path)
        descriptor = os.open(path, os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW)
        with os.fdopen(descriptor, 'w') as output:
            json.dump(config, output)
            output.flush()
            os.fsync(output.fileno())
        create(Path('/run/homelab-restore-fenced'), b'')
    elif operation == 'reset':
        need(not Path('/var/lib/rancher/rke2/server/db/etcd').exists())
        result = subprocess.run(['/usr/bin/rke2', 'server', '--config=/etc/rancher/rke2/config.yaml', '--cluster-reset',
                                 '--cluster-reset-restore-path=' + str(work / 'snapshot.zip')],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
        need(result.returncode == 0)
    elif operation == 'start':
        command(['systemctl', 'start', '--no-block', 'rke2-server'])
    elif operation == 'verify':
        target = payload['target']
        kubectl = ['/var/lib/rancher/rke2/bin/kubectl', '--kubeconfig=/etc/rancher/rke2/rke2.yaml',
                   '--server=https://127.0.0.1:6443', '--insecure-skip-tls-verify=false', '--request-timeout=10s']
        need(command(kubectl + ['get', '--raw=/readyz']) == 'ok')
        namespaces = json.loads(command(kubectl + ['get', 'namespaces', '-o', 'json']))['items']
        actual = {value['metadata']['name']: value['metadata']['uid'] for value in namespaces}
        need(all(actual.get(key) == value for key, value in target['namespace_uids'].items()))
        need(hashlib.sha256(Path('/var/lib/rancher/rke2/server/tls/server-ca.crt').read_bytes()).hexdigest() == target['server_ca_sha256'])
        cri = ['/var/lib/rancher/rke2/bin/crictl', '--runtime-endpoint=unix:///run/k3s/containerd/containerd.sock']
        containers = json.loads(command(cri + ['ps', '--name', '^etcd$', '-o', 'json']))['containers']
        need(len(containers) == 1)
        etcd = cri + ['exec', containers[0]['id'], 'etcdctl', '--endpoints=https://127.0.0.1:2379',
                      '--cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt', '--cert=/var/lib/rancher/rke2/server/tls/etcd/server-client.crt',
                      '--key=/var/lib/rancher/rke2/server/tls/etcd/server-client.key']
        members = json.loads(command(etcd + ['member', 'list', '-w', 'json']))['members']
        need(len(members) == 1 and not members[0].get('isLearner', False))
        health = json.loads(command(etcd + ['endpoint', 'health', '-w', 'json']))
        need(len(health) == 1 and health[0]['health'] is True)
        return {'successful': True, 'api_ready': True, 'expected_namespace_uids_preserved': True, 'server_ca_preserved': True,
                'single_nonlearner_etcd_member': True, 'etcd_healthy': True, 'selinux_enforcing': True}
    return {'successful': True}


if __name__ == '__main__':
    os.umask(0o077)
    try:
        need(len(sys.argv) == 1)
        data = sys.stdin.buffer.read(65537)
        need(0 < len(data) <= 65536)
        print(json.dumps(run(json.loads(data))))
    except Exception as error:
        print(json.dumps({'successful': False, 'error_type': type(error).__name__}))
