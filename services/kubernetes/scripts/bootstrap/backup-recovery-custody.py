#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import uuid

from kubernetes_object_store import cluster_name, private_bytes, private_json, require
from kubernetes_recovery import DATA, storage, token_hash


def validate_target(value):
    require(set(value) == {'endpoint', 'bucket', 'region', 'node_name', 'cluster_name', 'cluster_uid'}, 'Unexpected preparation target fields')
    storage({key: value[key] for key in ['endpoint', 'bucket', 'region']})
    require(value['bucket'] == cluster_name(value['cluster_name']) + '-backups' and
            str(uuid.UUID(value['cluster_uid'])) == value['cluster_uid'] and isinstance(value['node_name'], str) and value['node_name'],
            'Preparation target must identify the named cluster and source Node')
    return value


def validate_credentials(value):
    require(set(value) == {'access_key_id', 'secret_access_key'} and all(isinstance(v, str) and v for v in value.values()),
            'Expected independently recovered application backup credentials')
    return value


def credential_hash(value):
    return hashlib.sha256(json.dumps(validate_credentials(value), sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def validate_custody(target, credentials, value):
    require(set(value) == {'cluster_uid', 'backup_credential_sha256', 'server_token_hashes', 'independent_copies_confirmed'} and
            value['cluster_uid'] == target['cluster_uid'] and value['independent_copies_confirmed'] is True and
            value['backup_credential_sha256'] == credential_hash(credentials) and
            isinstance(value['server_token_hashes'], list) and value['server_token_hashes'] and
            all(isinstance(v, str) and re.fullmatch(r'[0-9a-f]{12}', v) for v in value['server_token_hashes']),
            'Independent recovery custody must match this cluster and credential pair')


def main():
    parser = argparse.ArgumentParser(description='Attest independently recovered copies without printing their values. This does not access OpenBao or prove a restore.')
    parser.add_argument('--config', required=True)
    parser.add_argument('--credentials-file', required=True)
    parser.add_argument('--server-token-file', required=True)
    parser.add_argument('--previous')
    parser.add_argument('--output', required=True)
    parser.add_argument('--independent-copies-confirmed', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        require(args.independent_copies_confirmed, 'Independently recovered copies must be confirmed')
        require(Path(args.server_token_file).resolve() != (DATA / 'server/token').resolve(),
                'Use an independently recovered token copy, not the live server token')
        target = validate_target(private_json(args.config))
        credentials = validate_credentials(private_json(args.credentials_file))
        association = token_hash(private_bytes(args.server_token_file).decode().strip())
        custody = private_json(args.previous) if args.previous else {
            'cluster_uid': target['cluster_uid'], 'server_token_hashes': [],
            'backup_credential_sha256': '', 'independent_copies_confirmed': False,
        }
        require(custody['cluster_uid'] == target['cluster_uid'], 'Previous custody belongs to a different cluster')
        custody['server_token_hashes'] = sorted(set(custody['server_token_hashes'] + [association]))
        custody['backup_credential_sha256'] = credential_hash(credentials)
        custody['independent_copies_confirmed'] = True
        validate_custody(target, credentials, custody)
        parent = Path(args.output).parent.stat()
        require(parent.st_uid == os.geteuid() and not stat.S_IMODE(parent.st_mode) & 0o022,
                'Output directory must be owned and not writable by others')
        descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'w') as output:
            os.fchmod(output.fileno(), 0o600)
            json.dump(custody, output, indent=2)
            output.write('\n')
    except (ValueError, OSError, TypeError, KeyError):
        parser.exit(1, 'Custody attestation failed; recovery-material details suppressed.\n')
    print('Private custody attestation written; no credential or token values displayed. Restore qualification remains separate.')


if __name__ == '__main__':
    main()
