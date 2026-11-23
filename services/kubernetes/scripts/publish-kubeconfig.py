#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
import uuid

from kubernetes_object_store import NativeS3, OperationError, cluster_name, https_origin, object_path, private_bytes, private_json, require


CONFIG = Path('/etc/rancher/rke2/config.yaml')


def target(value):
    require(set(value) == {'endpoint', 'region', 'bucket', 'cluster_name', 'cluster_uid', 'api_server', 'initializer', 'rke2_config_sha256'},
            'Unexpected publication metadata fields')
    https_origin(value['endpoint'])
    https_origin(value['api_server'])
    require(isinstance(value['cluster_uid'], str) and str(uuid.UUID(value['cluster_uid'])) == value['cluster_uid'], 'Invalid cluster UID')
    require(type(value['initializer']) is bool, 'Initializer eligibility must be explicit')
    require(isinstance(value['rke2_config_sha256'], str) and re.fullmatch(r'[0-9a-f]{64}', value['rke2_config_sha256']),
            'Expected the declared RKE2 configuration fingerprint')
    require(value['bucket'] == cluster_name(value['cluster_name']) + '-configuration', 'Publication bucket differs from the named cluster')
    object_path(value['bucket'], 'kubeconfig.yaml')
    require(isinstance(value['region'], str) and re.fullmatch(r'[a-z0-9-]+', value['region']), 'Invalid S3 region')
    return value


def initializing_server(metadata):
    config = private_bytes(CONFIG)
    require(hashlib.sha256(config).hexdigest() == metadata['rke2_config_sha256'], 'RKE2 configuration differs from the declared initializer')
    decision_path = Path('/var/lib/kubernetes-bootstrap/decision.json')
    fragments = list(CONFIG.with_name(CONFIG.name + '.d').glob('*'))
    if decision_path.exists():
        decision = private_json(decision_path)
        if decision['role'] == 'join':
            return False
        overlay = CONFIG.with_name(CONFIG.name + '.d') / '90-bootstrap.yaml'
        allowed = {overlay}
        snapshots = overlay.with_name('80-snapshots.yaml')
        if snapshots.exists():
            from kubernetes_recovery import snapshot_options, snapshot_settings

            native = private_json(snapshots)
            options = {key: native.get(key) for key in snapshot_options({})}
            require(native == snapshot_settings({'snapshots': options}), 'Unrecognized native snapshot configuration')
            allowed.add(snapshots)
        require(set(fragments) == allowed and decision['configuration_sha256'] == hashlib.sha256(config).hexdigest() and
                decision['overlay_sha256'] == hashlib.sha256(private_bytes(overlay)).hexdigest() and
                not private_json(overlay).get('server'), 'Managed runtime configuration differs from bootstrap result')
    else:
        require(not fragments, 'Additional RKE2 configuration needs an explicit role review')
    text = config.decode()
    if text.lstrip().startswith('{'):
        if json.loads(text).get('server'):
            return False
    elif re.search(r'''(?m)^\s*["']?server["']?\s*:''', text):
        return False
    status = subprocess.run(['systemctl', 'show', 'rke2-server', '--property=MainPID', '--value'],
                            capture_output=True, text=True, timeout=15)
    require(status.returncode == 0 and status.stdout.strip().isdigit(), 'Cannot identify the active RKE2 server')
    pid = int(status.stdout.strip())
    if pid == 0:
        return None
    require(Path('/proc', str(pid), 'exe').resolve() == Path('/usr/bin/rke2').resolve(), 'The RKE2 server is not running')
    arguments = Path('/proc', str(pid), 'cmdline').read_bytes().split(b'\0')
    if any(item in [b'--server', b'-s'] or item.startswith(b'--server=') for item in arguments):
        return False
    for index, item in enumerate(arguments):
        if item.startswith(b'--config='):
            require(item == b'--config=/etc/rancher/rke2/config.yaml', 'Unmanaged RKE2 configuration path')
        elif item in [b'--config', b'-c']:
            require(index + 1 < len(arguments) and arguments[index + 1] == b'/etc/rancher/rke2/config.yaml',
                    'Unmanaged RKE2 configuration path')
    environment = Path('/proc', str(pid), 'environ').read_bytes().split(b'\0')
    require(not any(item.startswith(b'RKE2_CONFIG_FILE=') and item != b'RKE2_CONFIG_FILE=/etc/rancher/rke2/config.yaml'
                    for item in environment), 'Unmanaged RKE2 configuration path')
    return not any(item.startswith(b'RKE2_URL=') and item != b'RKE2_URL=' for item in environment)


def export_config(kubectl, kubeconfig, metadata, deadline):
    private_bytes(kubeconfig, 131072)
    rendered = subprocess.run([kubectl, '--kubeconfig=' + str(kubeconfig), 'config', 'view', '--raw', '--flatten', '--minify', '-o', 'json'],
                              capture_output=True, timeout=20)
    require(rendered.returncode == 0, 'Native kubeconfig export failed')
    document = json.loads(rendered.stdout)
    require(len(document['clusters']) == 1 and len(document['users']) == 1, 'Unexpected kubeconfig shape')
    require(set(document['users'][0]['user']) == {'client-certificate-data', 'client-key-data'},
            'Only the native certificate-based RKE2 admin kubeconfig is supported')
    require(document['clusters'][0]['cluster'].get('certificate-authority-data') and
            not document['clusters'][0]['cluster'].get('insecure-skip-tls-verify') and
            not document['clusters'][0]['cluster'].get('proxy-url'), 'Native certificate verification is required')
    captured = json.dumps(document).encode()
    command = [kubectl, '--kubeconfig=/dev/stdin', '--server=https://127.0.0.1:6443',
               '--insecure-skip-tls-verify=false', '--request-timeout=15s']
    while time.monotonic() < deadline:
        try:
            ready = subprocess.run(command + ['get', '--raw=/readyz'], input=captured, capture_output=True,
                                   timeout=min(20, max(0.1, deadline - time.monotonic())))
            if ready.returncode == 0 and ready.stdout.strip() == b'ok':
                break
        except subprocess.TimeoutExpired:
            pass
        time.sleep(min(2, max(0, deadline - time.monotonic())))
    else:
        raise OperationError('Local API readiness deadline reached')
    namespace = subprocess.run(command + ['get', 'namespace', 'kube-system', '-o', 'json'], input=captured, capture_output=True, timeout=20)
    require(namespace.returncode == 0 and json.loads(namespace.stdout)['metadata']['uid'] == metadata['cluster_uid'],
            'Local cluster identity differs from publication scope')
    document['clusters'][0]['cluster']['server'] = https_origin(metadata['api_server'])
    return json.dumps(document, indent=2).encode()


def publish(client, metadata, payload, previous_sha256):
    path = object_path(metadata['bucket'], 'kubeconfig.yaml')
    if previous_sha256 is not None:
        status, etag, previous = client.request('GET', path)
        require(status == 200, 'Cannot retrieve the existing object for explicit refresh')
        require(hashlib.sha256(previous).hexdigest() == previous_sha256, 'Existing object does not match the approved refresh fingerprint')
        require(re.fullmatch(r'"[0-9a-fA-F]{32}(?:-[0-9]+)?"', etag), 'Unsupported object version identifier; no refresh performed')
        condition = 'If-Match: ' + etag
    else:
        condition = 'If-None-Match: *'
    status, _, _ = client.request('PUT', path, payload, headers=[condition, 'Content-Type: application/json'])
    if previous_sha256 is None and status == 412:
        status, _, existing = client.request('GET', path)
        require(status == 200 and existing == payload, 'Existing kubeconfig differs; explicit reviewed refresh is required')
        return 'Already published; identical contents verified without overwrite.'
    require(status == 200, 'Conditional upload failed or conflicted (HTTP ' + str(status) + '); existing object preserved')
    status, _, existing = client.request('GET', path)
    require(status == 200 and existing == payload, 'Published object contents were not verified')
    return 'Kubeconfig published and retrieved for content verification.'


def main():
    parser = argparse.ArgumentParser(description='Plan or explicitly publish an initializing server kubeconfig. Never displays credential contents.')
    parser.add_argument('--config', default='/etc/rancher/rke2/publication.json')
    parser.add_argument('--credentials-file', default='/etc/rancher/rke2/publication-credentials.json',
                        help='Root-only application credential JSON fetched from OpenBao, never operator credentials.')
    parser.add_argument('--kubectl', default='/var/lib/rancher/rke2/bin/kubectl')
    parser.add_argument('--kubeconfig', default='/etc/rancher/rke2/rke2.yaml')
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--wait-seconds', type=int, default=180, help='Bounded server/API readiness wait, from 1 to 900 seconds (default: 180).')
    parser.add_argument('--refresh-from-sha256', help='Explicitly replace only the object matching this previously approved content SHA-256.')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        metadata = target(private_json(args.config))
        require(1 <= args.wait_seconds <= 900, 'Readiness wait must be from 1 to 900 seconds')
        require(args.refresh_from_sha256 is None or re.fullmatch(r'[0-9a-f]{64}', args.refresh_from_sha256), 'Invalid refresh fingerprint')
        if not metadata['initializer']:
            print('Skipped: this host is not the cluster initializer. No kubeconfig or credential read.')
            return
        if not args.execute:
            print('Plan only: one cluster-scoped configuration object; no API calls, kubeconfig/credential reads or writes.')
            return
        require(os.geteuid() == 0, 'Publication requires root')
        require(subprocess.run(['getenforce'], capture_output=True, text=True, timeout=10).stdout.strip() == 'Enforcing',
                'SELinux must remain enforcing')
        deadline = time.monotonic() + args.wait_seconds
        eligibility = initializing_server(metadata)
        while eligibility is None and time.monotonic() < deadline:
            time.sleep(min(2, max(0, deadline - time.monotonic())))
            eligibility = initializing_server(metadata)
        require(eligibility is not None, 'RKE2 server startup deadline reached')
        if not eligibility:
            print('Skipped: this server is joining an existing cluster. No kubeconfig or credential read.')
            return
        payload = export_config(args.kubectl, Path(args.kubeconfig), metadata, deadline)
        client = NativeS3(metadata['endpoint'], metadata['region'], private_json(args.credentials_file))
        print(publish(client, metadata, payload, args.refresh_from_sha256))
    except OperationError as error:
        parser.exit(1, str(error) + '. No credential contents displayed.\n')
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError):
        parser.exit(1, 'Publication failed: verify initializer/configuration identity, API readiness, scoped OpenBao credentials and object collision state. No secret diagnostics displayed.\n')


if __name__ == '__main__':
    main()
