#!/usr/bin/env python3
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import time
from urllib.parse import urlsplit
import uuid


RKE2 = '/usr/bin/rke2'
VERSION = 'v1.36.6+rke2r1'
DATA = Path('/var/lib/rancher/rke2')
CREDENTIALS = Path('/etc/rancher/rke2/backup-credentials.json')
CUSTODY = Path('/etc/rancher/rke2/backup-recovery-custody.json')
REPORTS = DATA / 'homelab-backup-reports'
PREFIX = 'homelab-scheduled'
RETENTION_SECONDS = 14 * 86400


def require(condition, message):
    if not condition:
        raise ValueError(message)


def private_text(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor) as source:
        info = os.fstat(source.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and not stat.S_IMODE(info.st_mode) & 0o077,
                'Input must be an owned private regular file')
        text = source.read(65537)
        require(0 < len(text) <= 65536, 'Private input size is invalid')
    return text


def private_json(path):
    text = private_text(path)
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'Duplicate input field')
            result[key] = value
        return result
    return json.loads(text, object_pairs_hook=unique)


def validate_target(target):
    require(set(target) == {'endpoint', 'bucket', 'region', 'node_name', 'cluster_uid'}, 'Unexpected target fields')
    require(all(isinstance(value, str) and value for value in target.values()), 'Target values must be nonempty strings')
    endpoint = urlsplit(target['endpoint'])
    require(endpoint.scheme == 'https' and endpoint.hostname and not endpoint.username and not endpoint.password and
            endpoint.path in ['', '/'] and not endpoint.query and not endpoint.fragment and
            re.fullmatch(r'[a-z0-9.-]+(?::[0-9]{1,5})?', endpoint.netloc) and 0 < (endpoint.port or 443) <= 65535,
            'Target requires a verified HTTPS origin')
    require(re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', target['bucket']), 'Invalid bucket')
    require(re.fullmatch(r'[a-z0-9-]+', target['region']), 'Invalid region')
    require(re.fullmatch(r'[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?', target['node_name']), 'Invalid server node name')
    require(str(uuid.UUID(target['cluster_uid'])) == target['cluster_uid'], 'Invalid stable cluster UID')
    return target


def validate_credentials(credentials):
    require(set(credentials) == {'access_key_id', 'secret_access_key'} and
            all(isinstance(value, str) and re.fullmatch(r'[^\s]{1,1024}', value) for value in credentials.values()),
            'Expected the dedicated backup credential pair')
    return credentials


def credential_hash(credentials):
    return hashlib.sha256(json.dumps(validate_credentials(credentials), sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def server_token_hash(token):
    token = token.strip()
    require(token and not any(character.isspace() for character in token), 'Invalid recovery token format')
    if token.startswith('K10'):
        match = re.fullmatch(r'K10[0-9a-f]{64}::server:(.+)', token)
        require(match is not None, 'Expected the server recovery token, not an agent token')
        token = match.group(1)
    else:
        require(':' not in token, 'Unsupported recovery token format')
    return hashlib.sha256(token.encode()).hexdigest()[:12]


def validate_custody(target, credentials, custody):
    require(set(custody) == {'cluster_uid', 'backup_credential_sha256', 'server_token_hashes', 'independent_copies_confirmed'} and
            custody['cluster_uid'] == target['cluster_uid'] and custody['independent_copies_confirmed'] is True and
            custody['backup_credential_sha256'] == credential_hash(credentials) and
            isinstance(custody['server_token_hashes'], list) and custody['server_token_hashes'] and
            all(isinstance(value, str) and re.fullmatch(r'[0-9a-f]{12}', value) for value in custody['server_token_hashes']),
            'Independent recovery custody must match this cluster and credential pair')


def inventory(document, target, now):
    require(isinstance(document, dict) and isinstance(document.get('items'), list), 'Invalid native inventory')
    endpoint = urlsplit(target['endpoint'])
    authority = endpoint.hostname + ':' + str(endpoint.port or 443)
    pattern = re.compile(re.escape(PREFIX + '-' + target['node_name'] + '-') + r'([0-9]{10,})(?:\.zip)?$')
    result = []
    for item in document['items']:
        spec = item.get('spec', {})
        name = spec.get('snapshotName', '')
        match = pattern.fullmatch(name)
        if not match:
            continue
        remote = spec.get('s3')
        if remote is None:
            continue
        require(remote.get('endpoint') == authority and remote.get('bucket') == target['bucket'] and
                remote.get('prefix') == 'rke2/' + target['cluster_uid'] and remote.get('region') == target['region'] and
                remote.get('insecure', False) is False and remote.get('skipSSLVerify', False) is False and
                spec.get('nodeName') == target['node_name'] and item.get('status', {}).get('readyToUse') is True,
                'Owned snapshot target, identity or readiness differs')
        timestamp = int(match.group(1))
        require(timestamp <= now + 1, 'Owned snapshot timestamp is in the future')
        token_hash = item.get('metadata', {}).get('annotations', {}).get('etcd.rke2.cattle.io/snapshot-token-hash')
        require(isinstance(token_hash, str) and re.fullmatch(r'[0-9a-f]{12}', token_hash), 'Snapshot lacks recovery-token association')
        require(all(point['name'] != name for point in result), 'Duplicate owned snapshot')
        result.append({'name': name, 'timestamp': timestamp, 'token_hash': token_hash})
    return sorted(result, key=lambda point: point['timestamp'], reverse=True)


class Native:
    def __init__(self, target, credentials, runner=subprocess.run):
        self.target = validate_target(target)
        self.credentials = validate_credentials(credentials)
        self.runner = runner

    def __call__(self, operation, names=()):
        require(operation in ['ls', 'save', 'delete'], 'Unsupported native operation')
        endpoint = urlsplit(self.target['endpoint'])
        args = [RKE2, 'etcd-snapshot', operation, '--config=/dev/null', '--data-dir=' + str(DATA),
                '--etcd-server=https://127.0.0.1:9345', '--node-name=' + self.target['node_name'], '--debug=false',
                '--s3', '--s3-endpoint=' + endpoint.hostname + ':' + str(endpoint.port or 443),
                '--s3-bucket=' + self.target['bucket'], '--s3-folder=rke2/' + self.target['cluster_uid'],
                '--s3-region=' + self.target['region'], '--s3-bucket-lookup-type=path', '--s3-timeout=5m',
                '--s3-insecure=false', '--s3-skip-ssl-verify=false', '--s3-retention=0']
        if operation == 'ls':
            args.append('--output=json')
        if operation == 'save':
            args += ['--name=' + PREFIX, '--snapshot-compress', '--etcd-snapshot-retention=0']
        if operation == 'delete':
            pattern = re.escape(PREFIX + '-' + self.target['node_name'] + '-') + r'[0-9]{10,}(?:\.zip)?'
            require(0 < len(names) <= 8 and all(re.fullmatch(pattern, name) for name in names), 'Deletion outside owned snapshot scope')
            args += list(names)
        environment = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'HOME': '/root', 'LANG': 'C',
                       'AWS_ACCESS_KEY_ID': self.credentials['access_key_id'], 'AWS_SECRET_ACCESS_KEY': self.credentials['secret_access_key'],
                       'AWS_EC2_METADATA_DISABLED': 'true', 'AWS_CONFIG_FILE': '/dev/null', 'AWS_SHARED_CREDENTIALS_FILE': '/dev/null'}
        response = self.runner(args, env=environment, capture_output=True, text=True, timeout=450)
        require(response.returncode == 0, 'Native snapshot operation failed')
        if operation == 'ls':
            return json.loads(response.stdout)


def summary(points, now):
    return {'ready_snapshot_count': len(points),
            'latest_recovery_point_age_seconds': max(0, int(now - points[0]['timestamp'])) if points else None,
            'physical_version_cleanup_performed': False}


def run_backup(target, credentials, custody, native, now):
    validate_target(target)
    validate_custody(target, credentials, custody)
    clock = now if callable(now) else lambda: now
    started = clock()
    before = inventory(native('ls'), target, clock())
    require(all(point['token_hash'] in custody['server_token_hashes'] for point in before), 'Existing recovery-token association is not in custody')
    native('save')
    after = inventory(native('ls'), target, clock())
    new = [point for point in after if point['name'] not in {old['name'] for old in before} and point['timestamp'] >= started - 60]
    require(len(new) == 1 and new[0]['token_hash'] in custody['server_token_hashes'], 'New off-node recovery point or matching custody not verified')
    require(all(point['token_hash'] in custody['server_token_hashes'] for point in after), 'Recovery-token association changed during backup')
    expired = [point['name'] for point in reversed(after)
               if point['name'] != new[0]['name'] and point['timestamp'] < clock() - RETENTION_SECONDS][:8]
    if expired:
        native('delete', expired)
        after = inventory(native('ls'), target, clock())
        require(not set(expired) & {point['name'] for point in after}, 'Logical retirement is not verified')
    require(any(point['name'] == new[0]['name'] for point in after), 'New recovery point disappeared')
    result = summary(after, clock())
    result.update(logically_retired_count=len(expired),
                  logical_expired_remaining=sum(point['timestamp'] < clock() - RETENTION_SECONDS for point in after),
                  independent_recovery_custody_attested=True)
    return result


def run_status(target, credentials, custody, native, now):
    validate_target(target)
    validate_custody(target, credentials, custody)
    points = inventory(native('ls'), target, now)
    require(all(point['token_hash'] in custody['server_token_hashes'] for point in points), 'Recovery-token association is not in custody')
    return summary(points, now)


def write_report(operation, report):
    require(all(not path.is_symlink() for path in [REPORTS, *REPORTS.parents]), 'Unexpected report-directory symlink')
    REPORTS.mkdir(mode=0o700, exist_ok=True)
    info = REPORTS.stat()
    require(info.st_uid == os.geteuid() and not stat.S_IMODE(info.st_mode) & 0o077, 'Report directory must remain private to its owner')
    descriptor, temporary = tempfile.mkstemp(dir=REPORTS)
    try:
        with os.fdopen(descriptor, 'w') as output:
            os.fchmod(output.fileno(), 0o600)
            json.dump(report, output)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, REPORTS / (operation + '.json'))
    finally:
        with contextlib.suppress(FileNotFoundError):
            Path(temporary).unlink()


def verify_control_plane(target, runner=subprocess.run):
    require(os.geteuid() == 0 and (DATA / 'server/db/etcd').is_dir(), 'Execution requires the enrolled control-plane host')
    certificate = str(DATA / 'agent/client-kubelet.crt')
    verified = runner(['openssl', 'verify', '-purpose', 'sslclient', '-CAfile', str(DATA / 'server/tls/client-ca.crt'), certificate],
                      capture_output=True, text=True, timeout=15)
    require(verified.returncode == 0, 'Node certificate is not trusted by the local cluster')
    subject = runner(['openssl', 'x509', '-in', certificate, '-noout', '-subject', '-nameopt', 'RFC2253'],
                     capture_output=True, text=True, timeout=15)
    require(subject.returncode == 0 and subject.stdout.strip().startswith('subject=') and '\\' not in subject.stdout,
            'Cannot establish an unambiguous node certificate identity')
    attributes = subject.stdout.strip().removeprefix('subject=').split(',')
    require(attributes.count('CN=system:node:' + target['node_name']) == 1 and
            sum(attribute.startswith('CN=') for attribute in attributes) == 1 and
            attributes.count('O=system:nodes') == 1, 'Node certificate does not match the enrolled Kubernetes identity')


def main():
    parser = argparse.ArgumentParser(description='Plan or explicitly execute native, scoped off-node etcd backup operations. Never prints child output or recovery material.')
    parser.add_argument('operation', choices=['backup', 'status'])
    parser.add_argument('--config', default='/etc/rancher/rke2/backup-target.json')
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--max-age-seconds', type=int)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        target = validate_target(private_json(args.config))
        require(args.max_age_seconds is None or args.max_age_seconds > 0, 'Freshness bound must be positive')
        require(args.operation == 'status' or args.max_age_seconds is None, 'Freshness bounds apply only to status')
        if not args.execute:
            print('Plan only: no native command, credential access or writes. Six-hour schedule; fourteen-day logical recovery window; no version purge.')
            return
        verify_control_plane(target)
        descriptor = os.open('/run/homelab-etcd-backup.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                version = subprocess.run([RKE2, '--version'], capture_output=True, text=True, timeout=15)
                require(version.returncode == 0 and version.stdout.startswith('rke2 version ' + VERSION + ' '), 'Unsupported native RKE2 version')
                active = subprocess.run(['systemctl', 'is-active', '--quiet', 'rke2-server'], capture_output=True, timeout=15)
                require(active.returncode == 0, 'Control-plane service is not active')
                credentials = validate_credentials(private_json(CREDENTIALS))
                native = Native(target, credentials)
                if args.operation == 'backup':
                    result = run_backup(target, credentials, private_json(CUSTODY), native, time.time)
                    require(result['logical_expired_remaining'] == 0, 'Logical cleanup backlog remains after bounded batch')
                else:
                    result = run_status(target, credentials, private_json(CUSTODY), native, time.time())
                    require(result['ready_snapshot_count'] > 0 and (args.max_age_seconds is None or result['latest_recovery_point_age_seconds'] <= args.max_age_seconds),
                            'No recovery point within the requested freshness bound')
                write_report(args.operation, dict(result, successful=True, checked_at=int(time.time())))
            except (ValueError, OSError, TypeError, KeyError, subprocess.SubprocessError):
                with contextlib.suppress(OSError, ValueError):
                    write_report(args.operation, {'successful': False, 'checked_at': int(time.time()), 'details_suppressed': True})
                raise
        print('Native backup operation completed; private report updated. No recovery material displayed.')
    except (ValueError, OSError, TypeError, KeyError, subprocess.SubprocessError):
        parser.exit(1, 'Backup operation failed; details suppressed. Preserve existing recovery points and inspect the reviewed workflow.\n')


if __name__ == '__main__':
    main()
