#!/usr/bin/env python3
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

from kubernetes_object_store import NativeS3, OperationError, https_origin, object_path, private_bytes, private_json, require
from kubernetes_recovery import VERSION, check_native, token_hash


def prepare(args):
    spec = importlib.util.spec_from_file_location('etcd_backup', Path(__file__).with_name('etcd-backup.py'))
    backup = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(backup)
    target = backup.validate_target(private_json(args.config))
    https_origin(args.api_server)
    require(args.independent_copies_confirmed, 'Preparation needs independently recovered token/credential copies, not only live-host access')
    require(Path(args.server_token_file).resolve() != backup.DATA / 'server/token', 'Use the independent matching server-token copy, not the live token')
    check_native()
    backup.verify_control_plane(target)
    pair = backup.validate_credentials(private_json(args.credentials_file))
    custody = private_json(args.custody_file)
    backup.validate_custody(target, pair, custody)
    token = private_bytes(args.server_token_file).decode().strip()
    association = token_hash(token)
    require(association in custody['server_token_hashes'], 'Independently recovered token is not in the declared custody association')
    result = subprocess.run(['/var/lib/rancher/rke2/bin/kubectl', '--kubeconfig=/etc/rancher/rke2/rke2.yaml',
                             '--server=' + args.api_server, '--insecure-skip-tls-verify=false', '--request-timeout=15s',
                             'get', 'namespace', 'kube-system', '-o', 'json'], capture_output=True, timeout=20)
    require(result.returncode == 0 and json.loads(result.stdout)['metadata']['uid'] == target['cluster_uid'],
            'Stable API endpoint does not authenticate to the declared cluster')
    output = Path(args.output_directory)
    require(not any(path.is_symlink() for path in [output, *output.parents]), 'Preparation custody must not use symlinks')
    parent = output.parent.stat()
    require(parent.st_uid == 0 and not parent.st_mode & 0o077, 'Preparation needs an existing root-private custody parent')
    output.mkdir(mode=0o700)
    with (output / 'preparation-started.json').open('x') as destination:
        json.dump({'started_at': int(time.time()), 'independent_copies_confirmed': True}, destination)
    native = backup.Native(target, pair)
    before = backup.inventory(native('ls'), target, time.time())
    started = time.time()
    native('save')
    after = backup.inventory(native('ls'), target, time.time())
    fresh = [point for point in after if point['name'] not in {point['name'] for point in before} and point['timestamp'] >= started - 60]
    require(len(fresh) == 1 and fresh[0]['token_hash'] == association, 'Fresh off-node snapshot does not match the independently recovered server token')
    selected = fresh[0]
    key = 'rke2/' + target['cluster_uid'] + '/' + selected['name']
    client = NativeS3(target['endpoint'], target['region'], {'AWS_ACCESS_KEY_ID': pair['access_key_id'], 'AWS_SECRET_ACCESS_KEY': pair['secret_access_key']})
    snapshot = output / ('verified-snapshot.zip' if key.endswith('.zip') else 'verified-snapshot')
    downloaded = client.download(object_path(target['bucket'], key), snapshot, args.max_snapshot_bytes)
    point = {
        'cluster_uid': target['cluster_uid'], 'key': key, 'sha256': downloaded['sha256'], 'size': downloaded['size'],
        'token_hash': association, 'source_node': target['node_name'], 'timestamp': selected['timestamp'],
        'rke2_version': VERSION, 'api_server': args.api_server,
    }
    with (output / 'recovery-point.json').open('x') as destination:
        json.dump(point, destination, indent=2)
        destination.flush()
        os.fsync(destination.fileno())
    with (output / 'preparation-verified.json').open('x') as destination:
        json.dump({'successful': True, 'fresh_off_node_snapshot_download_verified': True,
                   'matching_independent_token_confirmed': True, 'snapshot_timestamp': selected['timestamp'],
                   'age_at_verification_seconds': int(time.time()) - selected['timestamp'],
                   'fencing_or_vm_destruction_authorized': False, 'restoration_or_application_volume_recovery_proven': False}, destination)


def main():
    parser = argparse.ArgumentParser(description='Prepare a fresh, downloaded and fingerprint-bound off-node recovery point before any separately approved fencing or replacement.')
    parser.add_argument('--config', default='/etc/rancher/rke2/backup-target.json')
    parser.add_argument('--credentials-file', required=True, help='Protected independently recovered application snapshot credential pair.')
    parser.add_argument('--server-token-file', required=True, help='Protected independently recovered matching server token, not the live default file.')
    parser.add_argument('--custody-file', default='/etc/rancher/rke2/backup-recovery-custody.json')
    parser.add_argument('--api-server', required=True, help='Stable verified HTTPS API origin.')
    parser.add_argument('--output-directory', required=True, help='New directory under an existing root-private custody parent.')
    parser.add_argument('--max-snapshot-bytes', type=int, default=2 * 1024 ** 3)
    parser.add_argument('--independent-copies-confirmed', action='store_true')
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        require(0 < args.max_snapshot_bytes <= 16 * 1024 ** 3, 'Invalid snapshot download bound')
        https_origin(args.api_server)
        if not args.execute:
            print('Plan only: fresh snapshot, actual off-node download and matching independent-token verification; no credential reads, API calls or writes.')
            return
        prepare(args)
        print('Recovery point prepared and downloaded; metadata and protected snapshot saved. Fencing, replacement and restoration still require separate approval.')
    except OperationError as error:
        parser.exit(1, str(error) + '. No recovery material displayed.\n')
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError):
        parser.exit(1, 'Preparation failed. Preserve phase artifacts and inspect native inventory before retrying; no fencing or replacement is authorized. No secret diagnostics displayed.\n')


if __name__ == '__main__':
    main()
