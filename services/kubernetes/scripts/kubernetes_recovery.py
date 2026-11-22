import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.request
import uuid

from kubernetes_object_store import OperationError, https_origin, object_path, private_json, require


DATA = Path('/var/lib/rancher/rke2')
STATE = Path('/var/lib/kubernetes-bootstrap')
CONFIG = Path('/etc/rancher/rke2/config.yaml')
TOKEN = Path('/etc/rancher/rke2/bootstrap-server-token')
VERSION = 'v1.36.6+rke2r1'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, stream, code, message, headers, url):
        return None


def canonical_sha256(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def backup_target(value):
    require(set(value) == {'endpoint', 'bucket', 'region'}, 'Unexpected backup-storage fields')
    https_origin(value['endpoint'])
    object_path(value['bucket'], 'rke2')
    require(isinstance(value['region'], str) and re.fullmatch(r'[a-z0-9-]+', value['region']), 'Invalid backup region')
    return value


def recovery_point(value):
    require(set(value) == {'cluster_uid', 'key', 'sha256', 'size', 'token_hash', 'source_node', 'timestamp', 'rke2_version', 'api_server'},
            'Unexpected recovery-point fields')
    require(str(uuid.UUID(value['cluster_uid'])) == value['cluster_uid'], 'Invalid recovery cluster identity')
    require(isinstance(value['source_node'], str) and re.fullmatch(r'[a-z0-9][a-z0-9-]{0,62}', value['source_node']), 'Invalid source Node name')
    require(type(value['timestamp']) is int and value['timestamp'] > 0, 'Invalid recovery-point timestamp')
    expected = 'rke2/' + value['cluster_uid'] + '/homelab-scheduled-' + value['source_node'] + '-' + str(value['timestamp'])
    require(value['key'] in [expected, expected + '.zip'], 'Snapshot key does not match its cluster, Node and timestamp')
    require(isinstance(value['sha256'], str) and re.fullmatch(r'[0-9a-f]{64}', value['sha256']), 'Invalid snapshot checksum')
    require(type(value['size']) is int and 0 < value['size'] <= 16 * 1024 ** 3, 'Invalid snapshot size')
    require(isinstance(value['token_hash'], str) and re.fullmatch(r'[0-9a-f]{12}', value['token_hash']), 'Invalid snapshot/token association')
    require(value['rke2_version'] == VERSION, 'Recovery point needs a separately reviewed RKE2 compatibility path')
    https_origin(value['api_server'])
    return value


def access(value, needs_s3, needs_token):
    require(set(value) == {'address', 'auth_mount', 'role_name', 'role_id', 'reader_policy', 's3_secret_path', 'server_token_path'},
            'Unexpected bootstrap enrollment fields')
    https_origin(value['address'])
    require(re.fullmatch(r'[a-z][a-z0-9-]*', value['auth_mount']), 'Invalid AppRole mount')
    require(re.fullmatch(r'kubernetes-[a-z0-9-]+-bootstrap', value['role_name']) and value['reader_policy'] == value['role_name'] + '-read',
            'Invalid bootstrap role/policy association')
    require(re.fullmatch(r'[A-Za-z0-9-]+', value['role_id']), 'Invalid bootstrap RoleID')
    for key, needed in [('s3_secret_path', needs_s3), ('server_token_path', needs_token)]:
        path = value[key]
        if not needed:
            require(path is None, 'Lifecycle must not grant an unused bootstrap record')
            continue
        require(isinstance(path, str) and re.fullmatch(r'[a-z][a-z0-9-]*/data/[A-Za-z0-9_/-]+', path) and
                path.split('/')[0] not in ['sys', 'auth', 'identity', 'cubbyhole'] and all(path.split('/')), 'Invalid exact bootstrap record path')
        if key == 'server_token_path':
            require(re.search(r'/server-token/[0-9a-f]{12}$', path), 'Use the existing fingerprint-addressed recovery token record')
        else:
            require('/server-token/' not in path, 'Snapshot credential enrollment must not target a server-token record')
    return value


def metadata(value):
    require(set(value) == {'mode', 'configuration_sha256', 'node_name', 'backup', 'access', 'recovery_point',
                           'fencing_confirmed', 'independent_custody_confirmed'}, 'Unexpected bootstrap metadata fields')
    require(value['mode'] in ['existing', 'create', 'join', 'restore'], 'Invalid bootstrap lifecycle mode')
    require(isinstance(value['configuration_sha256'], str) and re.fullmatch(r'[0-9a-f]{64}', value['configuration_sha256']),
            'Invalid RKE2 configuration fingerprint')
    require(isinstance(value['node_name'], str) and re.fullmatch(r'[a-z0-9][a-z0-9-]{0,62}', value['node_name']), 'Invalid declared Node name')
    require(type(value['fencing_confirmed']) is bool and type(value['independent_custody_confirmed']) is bool, 'Custody/fencing must be explicit')
    mode = value['mode']
    if mode != 'existing':
        access(value['access'], mode in ['create', 'restore'], mode in ['join', 'restore'])
    if mode in ['create', 'restore']:
        backup_target(value['backup'])
    if mode == 'restore':
        point = recovery_point(value['recovery_point'])
        require(value['node_name'] != point['source_node'], 'Same-name replacement Node-password handling is not qualified')
        require(value['fencing_confirmed'] and value['independent_custody_confirmed'], 'Restore requires explicit old-member fencing and independent token custody')
    else:
        require(value['recovery_point'] is None, 'Only restore mode may select a recovery point')
    return value


class BootstrapReader:
    def __init__(self, enrollment, approle_path):
        self.enrollment = enrollment
        self.origin = https_origin(enrollment['address'])
        self.token = None
        credential = private_json(approle_path)
        require(credential['role_id'] == enrollment['role_id'] and re.fullmatch(r'[A-Za-z0-9-]+', credential['secret_id']),
                'Enrolled bootstrap credential differs from its declared role')
        result = self.request('POST', 'auth/' + enrollment['auth_mount'] + '/login',
                              {'role_id': credential['role_id'], 'secret_id': credential['secret_id']})['auth']
        self.token = result['client_token']
        require(isinstance(self.token, str) and re.fullmatch(r'[A-Za-z0-9._-]+', self.token), 'Invalid bootstrap runtime token format')
        try:
            require(result['policies'] == [enrollment['reader_policy']] and not result.get('identity_policies') and
                    0 < result['lease_duration'] <= 900, 'Unexpected bootstrap reader policies/lifetime')
        except (OperationError, KeyError, TypeError):
            self.close()
            raise

    def request(self, method, path, value=None):
        headers = {'Content-Type': 'application/json'}
        if self.token:
            headers['X-Vault-Token'] = self.token
        request = urllib.request.Request(self.origin + '/v1/' + path, method=method, headers=headers,
                                         data=None if value is None else json.dumps(value).encode())
        try:
            with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
                data = response.read(131073)
                require(len(data) <= 131072, 'OpenBao response exceeds its bound')
                return json.loads(data) if data else {}
        except urllib.error.HTTPError as error:
            raise OperationError('Bootstrap OpenBao ' + method + ' request failed (HTTP ' + str(error.code) + ')') from None

    def read(self, field):
        try:
            return self.request('GET', self.enrollment[field])['data']['data']
        except OperationError as error:
            raise OperationError('Declared ' + field + ' record requires read access: ' + str(error)) from None

    def close(self):
        if self.token:
            try:
                self.request('POST', 'auth/token/revoke-self', {})
            except (OSError, OperationError):
                return False
            finally:
                self.token = None
        return True


def token_hash(value):
    require(isinstance(value, str) and value and not any(character.isspace() for character in value), 'Invalid server token format')
    if value.startswith('K10'):
        match = re.fullmatch(r'K10[0-9a-f]{64}::server:(.+)', value)
        require(match is not None, 'Expected a server recovery token, not an agent token')
        value = match.group(1)
    else:
        require(':' not in value, 'Unsupported server token format')
    return hashlib.sha256(value.encode()).hexdigest()[:12]


def check_native():
    require(os.geteuid() == 0, 'Bootstrap execution requires root')
    result = subprocess.run(['getenforce'], capture_output=True, timeout=10)
    require(result.returncode == 0 and result.stdout.strip() == b'Enforcing', 'SELinux must remain enforcing')
    result = subprocess.run(['/usr/bin/rke2', '--version'], capture_output=True, timeout=15)
    require(result.returncode == 0 and result.stdout.decode().splitlines()[0].split()[:3] == ['rke2', 'version', VERSION],
            'Installed RKE2 version differs from the qualified recovery version')
