#!/usr/bin/env python3
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET

from kubernetes_object_store import NativeS3, OperationError, object_path, private_bytes, private_json, require
from kubernetes_recovery import BootstrapReader, CONFIG, DATA, STATE, TOKEN, canonical_sha256, check_native, metadata, token_hash


def save_new(path, value):
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        json.dump(value, output, sort_keys=True)
        output.flush()
        os.fsync(output.fileno())
    parent = os.open(path.parent, os.O_DIRECTORY)
    try:
        os.fsync(parent)
    finally:
        os.close(parent)


def initialized():
    database = DATA / 'server/db/etcd'
    actual = database / 'member/snap/db'
    require(not any(path.is_symlink() for path in [actual, *actual.parents]), 'Datastore paths must not use symlinks')
    if not database.exists():
        return False
    require(actual.is_file(), 'Existing partial datastore requires inspection; it must not be initialized or overwritten')
    return True


def configuration(declaration):
    import yaml

    raw = private_bytes(CONFIG)
    require(hashlib.sha256(raw).hexdigest() == declaration['configuration_sha256'], 'RKE2 configuration differs from approved bootstrap intent')
    require(not any(CONFIG.with_name(CONFIG.name + '.d').glob('*')), 'Additional RKE2 configuration fragments require review')
    try:
        value = yaml.safe_load(raw)
    except yaml.YAMLError:
        raise OperationError('RKE2 configuration parsing failed; no configuration contents displayed') from None
    require(isinstance(value, dict) and value.get('node-name') == declaration['node_name'] and
            value.get('data-dir', str(DATA)) == str(DATA), 'Unmanaged RKE2 node identity or data directory')
    require(os.environ.get('RKE2_CONFIG_FILE', str(CONFIG)) == str(CONFIG), 'Unmanaged RKE2 configuration path')
    require(os.environ.get('RKE2_DATA_DIR', str(DATA)) == str(DATA) and
            os.environ.get('RKE2_NODE_NAME', declaration['node_name']) == declaration['node_name'], 'Unmanaged native data directory or Node-name override')
    require(not os.environ.get('RKE2_URL') or os.environ['RKE2_URL'] == value.get('server'), 'Unmanaged registration endpoint override')
    invocation = subprocess.run(['systemctl', 'show', 'rke2-server', '--property=ExecStart', '--value'], capture_output=True, timeout=15)
    commands = re.findall(r'argv\[\]=([^;]+);', invocation.stdout.decode())
    require(invocation.returncode == 0 and len(commands) == 1 and commands[0].strip() == '/usr/bin/rke2 server',
            'Unmanaged native RKE2 startup command requires review before empty-datastore bootstrap')
    joining = bool(value.get('server') or os.environ.get('RKE2_URL'))
    require(joining == (declaration['mode'] == 'join'), 'Join configuration and bootstrap lifecycle disagree')
    if declaration['mode'] in ['join', 'restore']:
        require(value.get('token-file') == str(TOKEN), 'Native RKE2 must use the separately enrolled server token')
        require(os.environ.get('RKE2_TOKEN_FILE', str(TOKEN)) == str(TOKEN), 'Unmanaged server-token file override')
    else:
        require(not value.get('token-file') and not value.get('token') and not os.environ.get('RKE2_TOKEN'),
                'New-cluster creation must not adopt an unrelated token')
    if declaration['mode'] == 'restore':
        origin = urlsplit(declaration['recovery_point']['api_server'])
        require(origin.hostname in value.get('tls-san', []) and (origin.port or 443) == 6443,
                'Restore must preserve the approved stable API certificate identity')
    return value


def read_inputs(declaration, approle):
    reader = BootstrapReader(declaration['access'], approle)
    try:
        pair, token = None, None
        if declaration['mode'] in ['create', 'restore']:
            pair = reader.read('s3_secret_path')
            require(set(pair) == {'access_key_id', 'secret_access_key'}, 'Unexpected snapshot-reader record schema')
            pair = {'AWS_ACCESS_KEY_ID': pair['access_key_id'], 'AWS_SECRET_ACCESS_KEY': pair['secret_access_key']}
        if declaration['mode'] in ['join', 'restore']:
            record = reader.read('server_token_path')
            require(set(record) == {'server_token'}, 'Unexpected server-token record schema')
            token = record['server_token']
            token_hash(token)
        return pair, token
    finally:
        reader.close()


def install_token(token):
    if TOKEN.exists() or TOKEN.is_symlink():
        require(private_bytes(TOKEN).decode().strip() == token, 'Existing bootstrap token differs; no overwrite performed')
        return
    descriptor = os.open(TOKEN, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        output.write(token + '\n')
        output.flush()
        os.fsync(output.fileno())


def restore(declaration, client, token):
    point = declaration['recovery_point']
    require(token_hash(token) == point['token_hash'], 'Enrolled server token does not match the selected snapshot association')
    snapshot = STATE / ('selected-snapshot.zip' if point['key'].endswith('.zip') else 'selected-snapshot')
    if snapshot.exists() or snapshot.is_symlink():
        descriptor = os.open(snapshot, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, 'rb') as source:
            info = os.fstat(source.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o077 and info.st_size == point['size'],
                    'Existing staged snapshot differs; preserve it for inspection')
            checksum = hashlib.file_digest(source, 'sha256').hexdigest()
        require(checksum == point['sha256'], 'Existing staged snapshot checksum differs')
    else:
        downloaded = client.download(object_path(declaration['backup']['bucket'], point['key']), snapshot, point['size'])
        require(downloaded == {'size': point['size'], 'sha256': point['sha256']}, 'Downloaded snapshot differs from the approved off-node recovery point')
    require(not initialized() and not (DATA / 'server/db').exists(), 'Datastore appeared during preparation; no reset performed')
    install_token(token)
    fingerprint = canonical_sha256(declaration)
    save_new(STATE / 'restore-started.json', {'intent_sha256': fingerprint, 'snapshot_sha256': point['sha256']})
    environment = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'HOME': '/root', 'LANG': 'C', 'RKE2_TOKEN': token}
    try:
        result = subprocess.run(['/usr/bin/rke2', 'server', '--config=' + str(CONFIG), '--data-dir=' + str(DATA),
                                 '--cluster-reset', '--cluster-reset-restore-path=' + str(snapshot), '--etcd-s3=false', '--debug=false'],
                                env=environment, capture_output=True, timeout=900)
    except subprocess.TimeoutExpired:
        save_new(STATE / 'restore-result.json', {'successful': False, 'timed_out': True})
        raise OperationError('Native reset timed out; preserve datastore and recovery receipts for inspection') from None
    save_new(STATE / 'restore-result.json', {'successful': result.returncode == 0, 'returncode': result.returncode})
    require(result.returncode == 0 and initialized(), 'Native reset failed or its datastore is incomplete; normal initialization remains blocked')
    save_new(STATE / 'restore-complete.json', {'intent_sha256': fingerprint, 'snapshot_sha256': point['sha256']})
    return 'Native snapshot restoration completed. Normal RKE2 startup may proceed; cluster/API/worker acceptance is still required.'


def execute(config_path, approle):
    require(os.geteuid() == 0, 'Bootstrap execution requires root')
    require(not any(path.is_symlink() for path in [STATE, *STATE.parents]), 'Bootstrap state must not use symlinks')
    STATE.mkdir(mode=0o700, exist_ok=True)
    info = STATE.stat()
    require(info.st_uid == 0 and not info.st_mode & 0o077, 'Bootstrap state must be private and root-owned')
    descriptor = os.open(STATE / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor) as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        started, complete = STATE / 'restore-started.json', STATE / 'restore-complete.json'
        require(not any(path.is_symlink() for path in [started, complete, STATE / 'restore-result.json']), 'Restore receipts must not use symlinks')
        if started.exists():
            require(complete.exists(), 'Incomplete or inconsistent restore attempt blocks startup; inspect preserved evidence before an approved retry')
            attempt, completion = private_json(started), private_json(complete)
            require(set(attempt) == {'intent_sha256', 'snapshot_sha256'} and attempt == completion and
                    all(isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) for value in attempt.values()) and
                    private_json(STATE / 'restore-result.json') == {'successful': True, 'returncode': 0},
                    'Incomplete or inconsistent restore attempt blocks startup; inspect preserved evidence before an approved retry')
        require(not complete.exists() or started.exists(), 'Restore completion has no matching attempt receipt')
        if initialized():
            return 'Initialized datastore preserved. No recovery credential read, snapshot download or reset.'
        require(not complete.exists(), 'Previously restored datastore is missing; no initialization or reset replay permitted')
        declaration = metadata(private_json(config_path))
        require(declaration['mode'] != 'existing', 'Empty datastore requires explicit create, join or restore intent; initialization is blocked')
        check_native()
        configuration(declaration)
        pair, token = read_inputs(declaration, approle)
        if declaration['mode'] == 'join':
            install_token(token)
            return 'Joining server: no snapshot access or restoration. Native cluster join may proceed.'
        target = declaration['backup']
        client = NativeS3(target['endpoint'], target['region'], pair)
        if declaration['mode'] == 'create':
            require(not (DATA / 'server/db').exists() and not (DATA / 'server/tls').exists(), 'Partial local bootstrap material requires inspection before creation')
            status, _, document = client.request('GET', '/' + target['bucket'] + '?list-type=2&max-keys=1')
            require(status == 200, 'Cannot verify absence of backup objects; new-cluster initialization is blocked (HTTP ' + str(status) + ')')
            root = ET.fromstring(document)
            require(root.tag.rsplit('}', 1)[-1] == 'ListBucketResult' and root.findtext('{*}KeyCount') == '0' and
                    root.findtext('{*}IsTruncated') == 'false' and not root.findall('{*}Contents'),
                    'Backup bucket is not confirmed empty; choose recovery rather than initializing a new cluster')
            status, _, document = client.request('GET', '/' + target['bucket'] + '?versions&max-keys=1')
            require(status == 200, 'Cannot verify absence of historical backup versions; initialization is blocked (HTTP ' + str(status) + ')')
            versions = ET.fromstring(document)
            require(versions.tag.rsplit('}', 1)[-1] == 'ListVersionsResult' and versions.findtext('{*}IsTruncated') == 'false' and
                    not versions.findall('{*}Version') and not versions.findall('{*}DeleteMarker'),
                    'Backup version history exists; creation must not bypass retained recovery points')
            return 'Explicit new-cluster creation approved after an authenticated empty backup-bucket check.'
        return restore(declaration, client, token)


def main():
    parser = argparse.ArgumentParser(description='Guard native RKE2 startup; never replaces initialized data or falls back from recovery to creation.')
    parser.add_argument('--config', default='/etc/rancher/rke2/bootstrap.json')
    parser.add_argument('--approle-file', default='/etc/rancher/rke2/bootstrap-approle.json')
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if not args.execute:
            declaration = metadata(private_json(args.config))
            print('Plan only: declared ' + declaration['mode'] + ' lifecycle; no credential reads, network calls, native commands or datastore writes.')
            return
        print(execute(Path(args.config), Path(args.approle_file)))
    except OperationError as error:
        parser.exit(1, str(error) + '. No recovery material or child diagnostics displayed.\n')
    except (ValueError, OSError, KeyError, TypeError, AttributeError, ImportError, subprocess.SubprocessError, ET.ParseError):
        parser.exit(1, 'Bootstrap failed closed. Inspect approved intent, enrollment and preserved attempt receipts; no automatic initialization or reset replay. No secret diagnostics displayed.\n')


if __name__ == '__main__':
    main()
