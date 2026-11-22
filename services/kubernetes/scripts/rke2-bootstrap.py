#!/usr/bin/env python3
import argparse
from contextlib import closing
import hashlib
import os
from pathlib import Path
import subprocess

from kubernetes_object_store import NativeS3, OperationError, object_path, private_bytes, private_json, require
from kubernetes_recovery import ACCESS, APPROLE, CONFIG, DATA, STATE, BootstrapReader, access, check_native, check_receipts, configuration, digest, endpoint_available, identity, initialized, install_token, latest_snapshot, lock_state, profile, save, token_hash


def restore(config, known, point, client, token):
    snapshot = STATE / ('selected-snapshot.zip' if point['key'].endswith('.zip') else 'selected-snapshot')
    selected = STATE / 'selected.json'
    if snapshot.exists():
        recorded = private_json(selected)
        require(all(recorded[key] == value for key, value in point.items()), 'Staged recovery point differs; inspect without overwriting')
        with snapshot.open('rb') as source:
            require(hashlib.file_digest(source, 'sha256').hexdigest() == recorded['sha256'], 'Staged snapshot checksum differs')
    else:
        downloaded = client.download(object_path(config['backup']['bucket'], point['key']), snapshot, point['size'], headers=['If-Match: ' + point['etag']])
        require(downloaded['size'] == point['size'], 'Snapshot size changed during download')
        recorded = dict(point, sha256=downloaded['sha256'])
        save(selected, recorded, exclusive=True)
    require(not (DATA / 'server/db').exists(), 'Datastore appeared before reset; no overwrite')
    receipt = {'intent_sha256': digest({'identity': known, 'snapshot': recorded}), 'snapshot_sha256': recorded['sha256']}
    save(STATE / 'restore-started.json', receipt, exclusive=True)
    try:
        result = subprocess.run(['/usr/bin/rke2', 'server', '--config=' + str(CONFIG), '--cluster-reset',
                                 '--cluster-reset-restore-path=' + str(snapshot), '--etcd-s3=false', '--debug=false'],
                                env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'HOME': '/root', 'LANG': 'C', 'RKE2_TOKEN': token},
                                capture_output=True, timeout=900)
    except subprocess.TimeoutExpired:
        save(STATE / 'restore-result.json', {'successful': False, 'timed_out': True}, exclusive=True)
        raise OperationError('Native reset timed out; preserved evidence blocks replay') from None
    save(STATE / 'restore-result.json', {'successful': result.returncode == 0, 'returncode': result.returncode}, exclusive=True)
    require(result.returncode == 0 and initialized(), 'Native restore failed; no initialization or replay allowed')
    require((DATA / 'server/tls/server-ca.crt').read_text().strip() == known['ca_certificate'].strip(), 'Restored CA differs from independent identity; startup blocked')
    save(STATE / 'restore-complete.json', receipt, exclusive=True)


def execute(enrollment, approle):
    with lock_state():
        check_receipts()
        if initialized():
            return 'Initialized datastore preserved. No discovery, credential read or reset.'
        require(not (STATE / 'restore-complete.json').exists(), 'Previously restored datastore is missing; no replay or creation')
        require(enrollment.exists(), 'Waiting for verified-SSH OpenBao enrollment; empty-datastore startup blocked')
        check_native()
        require(not (DATA / 'server/db').exists() and not (DATA / 'server/tls').exists(), 'Partial local bootstrap material requires inspection')
        with closing(BootstrapReader(private_json(enrollment), approle)) as reader:
            config = profile(reader.read('config_path'))
            known = identity(reader.read('identity_path'))
            record = reader.read('server_token_path')
            require(set(record) == {'server_token'}, 'Unexpected server-token record')
            token = record['server_token']
            association = token_hash(token)
            require(not known or association == known['token_hash'], 'Token differs from independent cluster identity')
            require(known is not None or not token.startswith('K10'), 'An existing secure server token requires independent cluster identity; do not create')
            if endpoint_available(config, known):
                role, point, client = 'join', None, None
            else:
                previous = private_json(STATE / 'decision.json') if (STATE / 'decision.json').exists() else None
                require(not previous or previous['role'] != 'join', 'Previously discovered join target is unavailable; wait without reading snapshots')
                pair = reader.read('s3_secret_path')
                require(set(pair) == {'access_key_id', 'secret_access_key'}, 'Unexpected application backup credential record')
                client = NativeS3(config['backup']['endpoint'], config['backup']['region'],
                                  {'AWS_ACCESS_KEY_ID': pair['access_key_id'], 'AWS_SECRET_ACCESS_KEY': pair['secret_access_key']})
                point = latest_snapshot(client, config, known, token)
                role = 'restore' if point else 'create'
        decision = configuration(role, config)
        install_token(token)
        if role == 'restore':
            restore(config, known, point, client, token)
        save(STATE / 'decision.json', decision)
        return 'Discovery selected ' + role + '. Native RKE2 startup may proceed; no VM asset changed.'


def main():
    parser = argparse.ArgumentParser(description='Preserve local etcd, otherwise discover join/restore/create after separate OpenBao enrollment; fail closed on uncertainty.')
    parser.add_argument('--enrollment', type=Path, default=ACCESS)
    parser.add_argument('--approle-file', type=Path, default=APPROLE)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.execute:
            print(execute(args.enrollment, args.approle_file))
        else:
            access(private_json(args.enrollment))
            print('Plan only: enrollment valid; no credential reads, discovery or writes.')
    except OperationError as error:
        parser.exit(1, str(error) + '. No secret or child diagnostics displayed.\n')
    except (ValueError, OSError, KeyError, TypeError, ImportError, subprocess.SubprocessError):
        parser.exit(1, 'Bootstrap failed closed; inspect enrollment, dependencies and preserved receipts. No secret diagnostics displayed.\n')


if __name__ == '__main__':
    main()
