#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import re
import ssl
import stat
import sys
from urllib.parse import urlsplit

import yaml


class PreparationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise PreparationError(message)


def fields(value, names):
    require(isinstance(value, dict) and set(value) == set(names), 'Input fields do not match the documented schema')


def name(value):
    require(isinstance(value, str) and len(value) <= 63 and
            re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?', value),
            'Names must be lowercase DNS labels of at most 63 characters')


def https_endpoint(value):
    require(isinstance(value, str), 'Endpoints must be HTTPS origins')
    parsed = urlsplit(value)
    require(parsed.scheme == 'https' and parsed.hostname and parsed.netloc and
            parsed.username is None and parsed.password is None and not parsed.query and not parsed.fragment and
            parsed.path in ['', '/'] and not any(c.isspace() for c in value),
            'Endpoints must be HTTPS origins without credentials, paths, queries or fragments')
    require(parsed.port is None or 1 <= parsed.port <= 65535, 'Endpoint port is invalid')


def validate(config):
    fields(config, ['openbao_address', 'kubernetes_host', 'kubernetes_ca_cert', 'api_audience', 'auth_mount', 'service'])
    https_endpoint(config['openbao_address'])
    https_endpoint(config['kubernetes_host'])
    name(config['auth_mount'])
    audience = config['api_audience']
    require(isinstance(audience, str) and 0 < len(audience) <= 256 and not any(c.isspace() for c in audience),
            'Supply one verified Kubernetes API audience')
    certificate = config['kubernetes_ca_cert']
    require(isinstance(certificate, str) and re.fullmatch(
        r'(?:-----BEGIN CERTIFICATE-----\n[A-Za-z0-9+/=\r\n]+\n-----END CERTIFICATE-----\s*)+', certificate),
        'Kubernetes trust must contain only PEM certificates, never keys')
    ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT).load_verify_locations(cadata=certificate)
    service = config['service']
    fields(service, ['namespace', 'service_account', 'role', 'policy', 'provider_class', 'objects'])
    for key in ['namespace', 'service_account', 'role', 'policy', 'provider_class']:
        name(service[key])
    objects = service['objects']
    require(isinstance(objects, list) and 1 <= len(objects) <= 32, 'Supply between one and 32 exact secret-file mappings')
    filenames = set()
    for obj in objects:
        fields(obj, ['file_name', 'secret_path', 'secret_key'])
        filename = obj['file_name']
        require(isinstance(filename, str) and len(filename) <= 128 and
                re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', filename) and filename not in filenames,
                'Secret filenames must be unique simple basenames')
        filenames.add(filename)
        path = obj['secret_path']
        require(isinstance(path, str) and len(path) <= 512 and
                re.fullmatch(r'[a-z0-9][a-z0-9-]*/data/[A-Za-z0-9._/-]+', path) and
                all(part not in ['', '.', '..'] for part in path.split('/')) and
                path.split('/')[0] not in ['sys', 'auth', 'identity', 'cubbyhole'],
                'Secret paths must be exact KV-v2 data paths without wildcards, traversal or query parameters')
        require(isinstance(obj['secret_key'], str) and re.fullmatch(r'[A-Za-z0-9_-]{1,128}', obj['secret_key']),
                'Secret keys must be simple field names')
    return config


def render(config):
    service = config['service']
    role_name = 'openbao-tokenreview'
    labels = {'app.kubernetes.io/managed-by': 'homelab', 'homelab.io/component': 'openbao-secrets'}
    role = {
        'apiVersion': 'rbac.authorization.k8s.io/v1', 'kind': 'ClusterRole',
        'metadata': {'name': role_name, 'labels': labels},
        'rules': [{'apiGroups': ['authentication.k8s.io'], 'resources': ['tokenreviews'], 'verbs': ['create']}],
    }
    binding = {
        'apiVersion': 'rbac.authorization.k8s.io/v1', 'kind': 'ClusterRoleBinding',
        'metadata': {'name': 'openbao-review-' + service['namespace'] + '.' + service['service_account'], 'labels': labels},
        'roleRef': {'apiGroup': 'rbac.authorization.k8s.io', 'kind': 'ClusterRole', 'name': role_name},
        'subjects': [{'kind': 'ServiceAccount', 'name': service['service_account'], 'namespace': service['namespace']}],
    }
    provider = {
        'apiVersion': 'secrets-store.csi.x-k8s.io/v1', 'kind': 'SecretProviderClass',
        'metadata': {'name': service['provider_class'], 'namespace': service['namespace'], 'labels': labels},
        'spec': {'provider': 'openbao', 'parameters': {
            'baoAddress': config['openbao_address'], 'baoAuthMountPath': config['auth_mount'],
            'roleName': service['role'], 'audience': config['api_audience'],
            'objects': yaml.safe_dump([
                {'objectName': obj['file_name'], 'secretPath': obj['secret_path'],
                 'secretKey': obj['secret_key'], 'filePermission': 0o444} for obj in service['objects']
            ], sort_keys=False),
        }},
    }
    paths = dict.fromkeys(obj['secret_path'] for obj in service['objects'])
    policy = '\n'.join('path ' + json.dumps(path) + ' {\n  capabilities = ["read"]\n}' for path in paths) + '\n'
    return {
        'platform-auth-config.json': json.dumps({
            'kubernetes_host': config['kubernetes_host'], 'kubernetes_ca_cert': config['kubernetes_ca_cert'],
            'token_reviewer_jwt': '', 'disable_local_ca_jwt': True, 'disable_iss_validation': True,
        }, indent=2) + '\n',
        'platform-tokenreview-role.yaml': yaml.safe_dump(role, sort_keys=False),
        'service-role.json': json.dumps({
            'bound_service_account_names': [service['service_account']],
            'bound_service_account_namespaces': [service['namespace']],
            'audience': config['api_audience'], 'token_policies': [service['policy']],
            'token_ttl': 300, 'token_max_ttl': 600, 'token_no_default_policy': True,
        }, indent=2) + '\n',
        'service-policy.hcl': policy,
        'service-enrollment.yaml': yaml.safe_dump_all([binding, provider], sort_keys=False),
    }


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON fields are not accepted')
        result[key] = value
    return result


def read_config(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd) as source:
        metadata = os.fstat(source.fileno())
        require(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid() and
                stat.S_IMODE(metadata.st_mode) in [0o400, 0o600], 'Input must be an operator-owned mode-0400/0600 regular file')
        require(metadata.st_size <= 1024 * 1024, 'Input exceeds the configuration size limit')
        return validate(json.load(source, object_pairs_hook=unique_fields))


def main():
    parser = argparse.ArgumentParser(description='Prepare private OpenBao Kubernetes authentication and service enrollment; no network or deployment.')
    parser.add_argument('--input', type=Path, required=True, help='Protected JSON configuration; never include credential or secret values')
    parser.add_argument('--output-dir', type=Path, required=True, help='New private directory outside the repository')
    args = parser.parse_args()
    os.umask(0o077)
    config = read_config(args.input)
    artifacts = render(config)
    repository = Path(__file__).resolve().parents[3]
    require(not args.output_dir.resolve().is_relative_to(repository), 'Prepared artifacts must stay outside the repository')
    args.output_dir.mkdir(mode=0o700)
    for filename, content in artifacts.items():
        fd = os.open(args.output_dir / filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as output:
            output.write(content)
    print('Prepared private authentication/enrollment artifacts. No network access, secret values or deployment; inspect ownership and trust before authorized use.')


if __name__ == '__main__':
    try:
        main()
    except PreparationError as error:
        print('Secret-auth preparation failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, TypeError, KeyError):
        print('Secret-auth preparation failed: check the protected input, certificate format and new output directory; no network operation was performed.', file=sys.stderr)
        sys.exit(1)
