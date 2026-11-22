#!/usr/bin/env python3
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import secrets
import stat
import subprocess
from urllib.parse import quote

from kubernetes_object_store import NativeS3, OperationError, cluster_name, https_origin, object_path, private_json, require


def publisher(value):
    require(set(value) == {'endpoint', 'region', 'bucket', 'cluster_name', 'key', 'policy'}, 'Unexpected publisher scope fields')
    https_origin(value['endpoint'])
    require(value['bucket'] == cluster_name(value['cluster_name']) + '-configuration' and value['key'] == 'kubeconfig.yaml',
            'Publisher needs its dedicated named-cluster bucket and exact configuration key')
    object_path(value['bucket'], value['key'])
    expected = {
        'Version': '2012-10-17',
        'Statement': [{
            'Effect': 'Allow',
            'Action': ['s3:GetObject', 's3:PutObject'],
            'Resource': ['arn:aws:s3:::' + value['bucket'] + '/' + value['key']],
        }],
    }
    require(value['policy'] == expected, 'Publisher policy must allow only content download/upload of its exact configuration object')
    return value


def backup(value):
    require(set(value) == {'endpoint', 'region', 'bucket', 'cluster_name', 'key', 'policy'}, 'Unexpected backup scope fields')
    https_origin(value['endpoint'])
    require(value['bucket'] == cluster_name(value['cluster_name']) + '-backups' and value['key'] == 'snapshots/*',
            'Backup access needs its dedicated named-cluster bucket and native snapshot folder')
    object_path(value['bucket'], 'snapshots')
    expected = {
        'Version': '2012-10-17',
        'Statement': [
            {'Effect': 'Allow', 'Action': ['s3:ListBucket', 's3:ListBucketVersions'],
             'Resource': ['arn:aws:s3:::' + value['bucket']]},
            {'Effect': 'Allow', 'Action': ['s3:GetObject', 's3:PutObject', 's3:DeleteObject'],
             'Resource': ['arn:aws:s3:::' + value['bucket'] + '/snapshots/*']},
        ],
    }
    require(value['policy'] == expected, 'Backup policy must exclude configuration objects, bucket administration and version purge')
    return value


def private_directory(path):
    path = Path(path).absolute()
    require(not any(item.is_symlink() for item in [path, *path.parents]), 'Credential custody must not use symlinks')
    info = path.stat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid() and not stat.S_IMODE(info.st_mode) & 0o077,
            'Credential custody parent must be an owned private directory')
    return path


def write_new(path, value):
    with open(path, 'x', encoding='utf-8') as output:
        json.dump(value, output, indent=2)
        output.flush()
        os.fsync(output.fileno())


def issue(scope, expiration, output, helper, purpose):
    require(expiration > datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=5),
            'Credential expiry must leave at least five minutes for enrollment')
    result = subprocess.run([helper, '--operator', 's3', '--output', 'json'], capture_output=True, timeout=60)
    require(result.returncode == 0, 'homelab-creds could not obtain the workstation S3 operator credential')
    operator = json.loads(result.stdout)
    require(https_origin(operator['AWS_ENDPOINT_URL_S3']) == scope['endpoint'], 'Operator endpoint differs from the approved publisher scope')
    client = NativeS3(scope['endpoint'], scope['region'], {key: operator[key] for key in ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY']})
    output = private_directory(output.parent) / output.name
    output.mkdir(mode=0o700)
    values = {'AWS_ACCESS_KEY_ID': 'K8S' + secrets.token_hex(9).upper(), 'AWS_SECRET_ACCESS_KEY': secrets.token_urlsafe(30)}
    stored = values if purpose == 'publication' else {'access_key_id': values['AWS_ACCESS_KEY_ID'], 'secret_access_key': values['AWS_SECRET_ACCESS_KEY']}
    write_new(output / 'credentials.json', stored)
    expiration_text = expiration.isoformat(timespec='seconds').replace('+00:00', 'Z')
    write_new(output / 'issuance-started.json', {'expiration': expiration_text, 'policy_sha256': hashlib.sha256(json.dumps(scope['policy'], sort_keys=True).encode()).hexdigest()})
    request = {
        'accessKey': values['AWS_ACCESS_KEY_ID'],
        'secretKey': values['AWS_SECRET_ACCESS_KEY'],
        'name': ('k8s-kubeconfig-' if purpose == 'publication' else 'k8s-backup-') + hashlib.sha256(scope['cluster_name'].encode()).hexdigest()[:12],
        'description': 'Kubernetes ' + purpose + ' application credential; no other cluster or bucket access',
        'expiration': expiration_text,
        'expiry': False,
        'impliedPolicy': False,
        'policy': json.dumps(scope['policy']),
    }
    status, _, response = client.request('PUT', '/rustfs/admin/v3/add-service-accounts', json.dumps(request).encode(),
                                        headers=['Content-Type: application/json'])
    write_new(output / 'issuance-result.json', {'http_status': status})
    require(200 <= status < 300, 'Publisher issuance failed (HTTP ' + str(status) + '); required operation: PUT /rustfs/admin/v3/add-service-accounts. Inspect custody before retrying')
    returned = json.loads(response)['credentials']
    require(returned.get('accessKey') == values['AWS_ACCESS_KEY_ID'] and returned.get('secretKey') == values['AWS_SECRET_ACCESS_KEY'],
            'RustFS did not confirm the requested credential pair; preserve custody and inspect the account')
    status, _, response = client.request('GET', '/rustfs/admin/v3/info-service-account?accessKey=' + quote(values['AWS_ACCESS_KEY_ID'], safe=''))
    require(status == 200, 'Publisher inspection failed (HTTP ' + str(status) + '); required operation: GET /rustfs/admin/v3/info-service-account. Do not enroll unverified credentials')
    actual = json.loads(response)
    policy = actual.get('policy')
    if isinstance(policy, str):
        policy = json.loads(policy)
    require(policy == scope['policy'] and actual.get('impliedPolicy') is False, 'Issued publisher scope differs from the exact application policy')
    require(actual.get('expiration') == expiration_text, 'Issued publisher expiry differs from the approved time')
    write_new(output / 'scope-verified.json', {'successful': True, 'expiration': expiration_text,
                                             'purpose': purpose, 'implied_policy': False})


def main():
    parser = argparse.ArgumentParser(description='Issue separate named-cluster RustFS application credentials using workstation operator access, outside OpenTofu state.')
    parser.add_argument('--purpose', choices=['publication', 'backup'], default='publication')
    parser.add_argument('--scope', required=True, help='Protected artifacts-root publisher output.')
    parser.add_argument('--expires-at', required=True, help='Operator-approved UTC expiry, in ISO-8601 format.')
    parser.add_argument('--output-directory', required=True, type=Path, help='New custody directory under an existing private parent; never reused.')
    parser.add_argument('--credential-helper', default='homelab-creds')
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        scope = {'publication': publisher, 'backup': backup}[args.purpose](private_json(args.scope))
        expiration = datetime.datetime.fromisoformat(args.expires_at.replace('Z', '+00:00'))
        require(expiration.tzinfo is not None and expiration.utcoffset() == datetime.timedelta(0), 'Use an explicit UTC expiration')
        if not args.execute:
            print('Plan only: one declared-scope application credential; no operator lookup, API calls or custody writes.')
            return
        issue(scope, expiration, args.output_directory, args.credential_helper, args.purpose)
        print('Application credential issued and scope verified. Enroll credentials.json into its exact OpenBao record using the bounded writer; never deliver the operator credential to the host.')
    except OperationError as error:
        parser.exit(1, str(error) + '. No credential contents displayed.\n')
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError):
        parser.exit(1, 'Publisher issuance failed. Preserve any custody directory and inspect the account before an explicit retry. No secret diagnostics displayed.\n')


if __name__ == '__main__':
    main()
