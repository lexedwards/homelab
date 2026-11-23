import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET

from kubernetes_object_store import NativeS3, OperationError, cluster_name, https_origin, object_path, private_bytes, private_json, require

DATA = Path('/var/lib/rancher/rke2')
STATE = Path('/var/lib/kubernetes-bootstrap')
CONFIG = Path('/etc/rancher/rke2/config.yaml')
OVERLAY = CONFIG.with_name('config.yaml.d') / '90-bootstrap.yaml'
TOKEN = Path('/etc/rancher/rke2/bootstrap-server-token')
ACCESS = Path('/etc/rancher/rke2/bootstrap-access.json')
APPROLE = Path('/etc/rancher/rke2/bootstrap-approle.json')
VERSION = 'v1.36.6+rke2r1'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, stream, code, message, headers, url):
        return None


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def save(path, value, exclusive=False):
    require(not any(p.is_symlink() for p in [path, *path.parents]), 'Private output must not use symlinks')
    temporary = path.with_name(path.name + '.pending')
    descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(descriptor, 'w') as output:
            json.dump(value, output, sort_keys=True)
            output.flush()
            os.fsync(output.fileno())
        if exclusive:
            os.link(temporary, path)
        else:
            os.replace(temporary, path)
        parent = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    finally:
        temporary.unlink(missing_ok=True)


def lock_state():
    require(os.geteuid() == 0, 'Bootstrap execution requires root')
    require(not any(p.is_symlink() for p in [STATE, *STATE.parents]), 'Bootstrap state must not use symlinks')
    STATE.mkdir(mode=0o700, exist_ok=True)
    info = STATE.stat()
    require(info.st_uid == 0 and not info.st_mode & 0o077, 'Bootstrap state must remain root-private')
    descriptor = os.open(STATE / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    lock = os.fdopen(descriptor)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    return lock


def initialized():
    path = DATA / 'server/db/etcd/member/snap/db'
    require(not any(p.is_symlink() for p in [path, *path.parents]), 'Datastore paths must not use symlinks')
    if not path.is_file():
        db, tls = DATA / 'server/db', DATA / 'server/tls'
        require(not tls.exists() and not tls.is_symlink(), 'Existing TLS material requires inspection; no overwrite')
        for entry in [db, *db.rglob('*')] if db.exists() else []:
            require(entry.is_dir() and not entry.is_symlink() and entry.stat().st_uid == 0 and not entry.stat().st_mode & 0o022,
                    'Existing partial datastore requires inspection; no initialization or overwrite')
        return False
    return True


def check_receipts():
    started, complete = STATE / 'restore-started.json', STATE / 'restore-complete.json'
    require(not any(p.is_symlink() for p in [started, complete, STATE / 'restore-result.json']), 'Restore receipts must not use symlinks')
    if started.exists():
        require(complete.exists() and private_json(started) == private_json(complete) and
                private_json(STATE / 'restore-result.json') == {'successful': True, 'returncode': 0},
                'Incomplete or inconsistent restore attempt blocks startup; inspect preserved evidence')
    require(not complete.exists() or started.exists(), 'Restore completion has no matching attempt')


def storage(value):
    require(set(value) == {'endpoint', 'bucket', 'region'}, 'Unexpected object-storage fields')
    https_origin(value['endpoint'])
    object_path(value['bucket'], 'rke2')
    require(re.fullmatch(r'[a-z0-9-]+', value['region']), 'Invalid object-storage region')
    return value


def access(value):
    fields = {'address', 'auth_mount', 'role_name', 'role_id', 'reader_policy', 'config_path', 'identity_path',
              'server_token_path', 's3_secret_path', 'publication_secret_path', 'cluster_name', 'identity_token_role', 'identity_writer_policy'}
    require(set(value) == fields, 'Unexpected bootstrap enrollment fields')
    https_origin(value['address'])
    require(re.fullmatch(r'[a-z][a-z0-9-]*', value['auth_mount']), 'Invalid AppRole mount')
    require(value['role_name'] == 'kubernetes-' + cluster_name(value['cluster_name']) + '-bootstrap' and value['reader_policy'] == value['role_name'] + '-read',
            'Invalid bootstrap role/policy association')
    require(re.fullmatch(r'[A-Za-z0-9-]+', value['role_id']), 'Invalid RoleID')
    require(value['identity_token_role'] == 'kubernetes-' + value['cluster_name'] + '-identity' and
            value['identity_writer_policy'] == value['identity_token_role'], 'Invalid first-identity writer association')
    paths = [value[key] for key in fields if key.endswith('_path')]
    require(len(set(paths)) == len(paths), 'Enrollment records must be distinct')
    for path in paths:
        require(isinstance(path, str) and re.fullmatch(r'[a-z][a-z0-9-]*/data/[A-Za-z0-9_/-]+', path) and
                path.split('/')[0] not in ['sys', 'auth', 'identity', 'cubbyhole'] and all(path.split('/')), 'Invalid exact OpenBao record path')
    return value


def profile(value):
    require(set(value) == {'cluster_name', 'api_server', 'registration_server', 'backup', 'publication'}, 'Unexpected runtime profile fields')
    https_origin(value['api_server'])
    https_origin(value['registration_server'])
    require(urllib.parse.urlsplit(value['api_server']).hostname == urllib.parse.urlsplit(value['registration_server']).hostname,
            'API and registration must use the same published cluster identity')
    storage(value['backup'])
    storage(value['publication'])
    name = cluster_name(value['cluster_name'])
    require(value['backup']['bucket'] == name + '-backups' and value['publication']['bucket'] == name + '-configuration',
            'Runtime storage must use the named cluster\'s two dedicated buckets')
    return value


def identity(value):
    if value is None:
        return None
    require(set(value) == {'cluster_uid', 'ca_certificate', 'rke2_version', 'token_hash'}, 'Unexpected cluster identity fields')
    require(str(uuid.UUID(value['cluster_uid'])) == value['cluster_uid'] and value['rke2_version'] == VERSION,
            'Cluster identity or snapshot-version compatibility is invalid')
    require(re.fullmatch(r'[0-9a-f]{12}', value['token_hash']), 'Invalid token association')
    ssl.create_default_context(cadata=value['ca_certificate'])
    return value


class BootstrapReader:
    def __init__(self, enrollment, approle_path=APPROLE):
        self.enrollment = access(enrollment)
        self.token = None
        credential = private_json(approle_path)
        require(credential['role_id'] == enrollment['role_id'] and re.fullmatch(r'[A-Za-z0-9-]+', credential['secret_id']), 'AppRole custody differs')
        auth = self.request('POST', 'auth/' + enrollment['auth_mount'] + '/login',
                            {'role_id': credential['role_id'], 'secret_id': credential['secret_id']})['auth']
        self.token = auth['client_token']
        require(re.fullmatch(r'[A-Za-z0-9._-]+', self.token), 'Invalid runtime token')
        try:
            require(auth['policies'] == [enrollment['reader_policy']] and not auth.get('identity_policies') and
                    0 < auth['lease_duration'] <= 900, 'Unexpected bootstrap reader policies/lifetime')
        except (OperationError, KeyError, TypeError):
            self.close()
            raise

    def request(self, method, path, value=None, missing=False, token=None):
        headers = {'Content-Type': 'application/json'}
        if self.token:
            headers['X-Vault-Token'] = token or self.token
        request = urllib.request.Request(https_origin(self.enrollment['address']) + '/v1/' + path, method=method, headers=headers,
                                         data=None if value is None else json.dumps(value).encode())
        try:
            with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
                data = response.read(131073)
                require(len(data) <= 131072, 'OpenBao response too large')
                return json.loads(data) if data else {}
        except urllib.error.HTTPError as error:
            if missing and error.code == 404:
                return None
            raise OperationError('Bootstrap OpenBao ' + method + ' failed (HTTP ' + str(error.code) + ')') from None

    def read(self, field):
        result = self.request('GET', self.enrollment[field], missing=field == 'identity_path')
        if result is None:
            metadata_path = self.enrollment['identity_path'].replace('/data/', '/metadata/', 1)
            history = self.request('GET', metadata_path, missing=True)
            require(history is None or (history['data']['current_version'] == 0 and not history['data'].get('versions')),
                    'Cluster identity has retained metadata/history; deletion does not permit creation')
        return None if result is None else result['data']['data']

    def record_identity(self, value):
        auth = self.request('POST', 'auth/token/create/' + self.enrollment['identity_token_role'], {
            'policies': [self.enrollment['identity_writer_policy']], 'ttl': '60s', 'explicit_max_ttl': '60s',
            'renewable': False, 'no_default_policy': True})['auth']
        require(re.fullmatch(r'[A-Za-z0-9._-]+', auth['client_token']), 'Invalid first-identity writer token')
        try:
            require(auth['policies'] == [self.enrollment['identity_writer_policy']] and not auth.get('identity_policies') and
                    0 < auth['lease_duration'] <= 60 and auth['renewable'] is False, 'Unexpected identity-writer authority')
            self.request('POST', self.enrollment['identity_path'], {'options': {'cas': '0'}, 'data': identity(value)}, token=auth['client_token'])
        finally:
            self.request('POST', 'auth/token/revoke-self', {}, token=auth['client_token'])

    def close(self):
        if self.token:
            try:
                self.request('POST', 'auth/token/revoke-self', {})
            except (OSError, OperationError):
                pass
            self.token = None


def token_hash(value):
    require(isinstance(value, str) and value and not any(c.isspace() for c in value), 'Invalid server token format')
    if value.startswith('K10'):
        match = re.fullmatch(r'K10[0-9a-f]{64}::server:(.+)', value)
        require(match is not None, 'Expected a server token')
        value = match.group(1)
    else:
        require(':' not in value, 'Unsupported server token')
    return hashlib.sha256(value.encode()).hexdigest()[:12]


def check_native():
    require(subprocess.run(['getenforce'], capture_output=True, timeout=10).stdout.strip() == b'Enforcing', 'SELinux must remain enforcing')
    result = subprocess.run(['/usr/bin/rke2', '--version'], capture_output=True, timeout=15)
    require(result.returncode == 0 and result.stdout.decode().splitlines()[0].split()[:3] == ['rke2', 'version', VERSION], 'Unqualified RKE2 version')


def endpoint_available(config, known):
    context = ssl.create_default_context(cadata=known['ca_certificate']) if known else ssl.create_default_context()
    request = urllib.request.Request(config['registration_server'] + '/ping')
    try:
        with urllib.request.build_opener(NoRedirect, urllib.request.HTTPSHandler(context=context)).open(request, timeout=5) as response:
            require(response.status == 200 and response.read(16).strip() == b'pong', 'Endpoint is responding but not a healthy RKE2 supervisor')
            require(known is not None, 'Existing endpoint needs the independently recorded cluster identity before joining')
            return True
    except urllib.error.HTTPError:
        raise OperationError('Cluster endpoint responded but is not joinable; retry, do not restore') from None
    except urllib.error.URLError as error:
        if isinstance(error.reason, ConnectionRefusedError):
            return False
        raise OperationError('Cluster endpoint status is uncertain (DNS/TLS/timeout/network); retry without initialization') from None


def objects(client, target, prefix='', versions=False):
    token = None
    for _ in range(100):
        query = ('versions&max-keys=100' if versions else 'list-type=2&max-keys=100') + '&prefix=' + urllib.parse.quote(prefix, safe='')
        if token:
            query += '&continuation-token=' + urllib.parse.quote(token, safe='')
        status, _, body = client.request('GET', '/' + target['bucket'] + '?' + query)
        require(status == 200, 'Backup inventory failed (HTTP ' + str(status) + '); absence is not established')
        root = ET.fromstring(body)
        require(root.tag.rsplit('}', 1)[-1] == ('ListVersionsResult' if versions else 'ListBucketResult'), 'Invalid S3 inventory response')
        if versions:
            require(not root.findall('{*}Version') and not root.findall('{*}DeleteMarker') and root.findtext('{*}IsTruncated') == 'false',
                    'Retained backup history prevents new-cluster creation')
            return
        for item in root.findall('{*}Contents'):
            yield item.findtext('{*}Key')
        if root.findtext('{*}IsTruncated') == 'false':
            return
        token = root.findtext('{*}NextContinuationToken')
        require(token, 'Truncated inventory has no continuation token')
    raise OperationError('Backup inventory exceeded its bounded page limit')


def latest_snapshot(client, config, known, token):
    target = config['backup']
    keys = list(objects(client, target, 'snapshots/' if known else ''))
    if not known:
        require(not keys, 'Backups exist but cluster identity is missing; do not create')
        list(objects(client, target, versions=True))
        return None
    require(known['token_hash'] == token_hash(token), 'Server token differs from independent cluster identity')
    candidates = []
    for key in keys:
        match = re.fullmatch(r'snapshots/homelab-scheduled-([a-z0-9-]+)-([0-9]{10,})(\.zip)?', key or '')
        if match:
            candidates.append((int(match[2]), key, match[1]))
    require(candidates, 'Known cluster has no usable backup; new-cluster creation is forbidden')
    candidates.sort(reverse=True)
    require(len(candidates) == 1 or candidates[0][0] != candidates[1][0], 'Newest recovery point is ambiguous')
    timestamp, key, node = candidates[0]
    status, info = client.head(object_path(target['bucket'], key))
    require(status == 200 and info['token_hash'] == known['token_hash'] and info['node_name'] == node, 'Newest snapshot metadata/token association is invalid')
    require(re.fullmatch(r'"[0-9a-fA-F]{32}(?:-[0-9]+)?"', info['etag']) and info['size'].isdigit() and
            0 < int(info['size']) <= 16 * 1024 ** 3, 'Snapshot size or immutable object identifier is invalid')
    return {'key': key, 'timestamp': timestamp, 'size': int(info['size']), 'etag': info['etag']}


def configuration(role, config):
    import yaml

    base = private_bytes(CONFIG)
    try:
        document = yaml.safe_load(base)
    except yaml.YAMLError:
        raise OperationError('Invalid native configuration; contents suppressed') from None
    require(isinstance(document, dict) and document.get('with-node-id') is True and
            urllib.parse.urlsplit(config['api_server']).hostname in document.get('tls-san', []), 'Base configuration does not match the stable cluster endpoint/unique Node contract')
    require(not document.get('server') and not document.get('token') and not document.get('token-file') and
            document.get('data-dir', str(DATA)) == str(DATA), 'Base configuration must be installation-only')
    require(not any(k in os.environ for k in ['RKE2_URL', 'RKE2_TOKEN', 'RKE2_TOKEN_FILE', 'RKE2_CONFIG_FILE', 'RKE2_DATA_DIR', 'RKE2_NODE_NAME']),
            'Unmanaged RKE2 environment overrides require inspection')
    OVERLAY.parent.mkdir(mode=0o700, exist_ok=True)
    require(not any(path != OVERLAY for path in OVERLAY.parent.glob('*')), 'Unmanaged native configuration fragments')
    value = {'token-file': str(TOKEN)}
    if role == 'join':
        value['server'] = config['registration_server']
    if OVERLAY.exists():
        require(private_json(OVERLAY) == value, 'Existing runtime configuration differs; no overwrite')
    else:
        save(OVERLAY, value, exclusive=True)
    return {'role': role, 'configuration_sha256': hashlib.sha256(base).hexdigest(), 'overlay_sha256': hashlib.sha256(private_bytes(OVERLAY)).hexdigest()}


def install_token(token):
    if TOKEN.exists() or TOKEN.is_symlink():
        require(private_bytes(TOKEN).decode().strip() == token, 'Existing server token differs; no overwrite')
        return
    descriptor = os.open(TOKEN, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        output.write(token + '\n')
        output.flush()
        os.fsync(output.fileno())
