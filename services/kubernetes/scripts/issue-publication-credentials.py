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
import uuid

from kubernetes_object_store import NativeS3, OperationError, https_origin, object_path, private_json, require


def publisher(value):
    require(set(value) == {'endpoint', 'region', 'bucket', 'cluster_uid', 'key', 'policy'}, 'Unexpected publisher scope fields')
    https_origin(value['endpoint'])
    if value['cluster_uid'] is not None:
        require(str(uuid.UUID(value['cluster_uid'])) == value['cluster_uid'], 'Invalid cluster identity')
    require(value['key'] == 'rke2/' + (value['cluster_uid'] or '*') + '/kubeconfig.yaml', 'Unexpected publisher object scope')
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


def issue(scope, expiration, output, helper):
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
    write_new(output / 'credentials.json', values)
    expiration_text = expiration.isoformat(timespec='seconds').replace('+00:00', 'Z')
    write_new(output / 'issuance-started.json', {'expiration': expiration_text, 'policy_sha256': hashlib.sha256(json.dumps(scope['policy'], sort_keys=True).encode()).hexdigest()})
    request = {
        'accessKey': values['AWS_ACCESS_KEY_ID'],
        'secretKey': values['AWS_SECRET_ACCESS_KEY'],
        'name': 'k8s-kubeconfig-' + hashlib.sha256((scope['cluster_uid'] or scope['bucket']).encode()).hexdigest()[:12],
        'description': 'Kubernetes configuration-object publisher; no backup-bucket access',
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
                                             'cluster_uid_known': scope['cluster_uid'] is not None, 'implied_policy': False})


def main():
    parser = argparse.ArgumentParser(description='Issue a separate RustFS kubeconfig publisher using workstation operator credentials, outside OpenTofu state.')
    parser.add_argument('--scope', required=True, help='Protected artifacts-root publisher output.')
    parser.add_argument('--expires-at', required=True, help='Operator-approved UTC expiry, in ISO-8601 format.')
    parser.add_argument('--output-directory', required=True, type=Path, help='New custody directory under an existing private parent; never reused.')
    parser.add_argument('--credential-helper', default='homelab-creds')
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        scope = publisher(private_json(args.scope))
        expiration = datetime.datetime.fromisoformat(args.expires_at.replace('Z', '+00:00'))
        require(expiration.tzinfo is not None and expiration.utcoffset() == datetime.timedelta(0), 'Use an explicit UTC expiration')
        if not args.execute:
            print('Plan only: one declared-scope application credential; no operator lookup, API calls or custody writes.')
            return
        issue(scope, expiration, args.output_directory, args.credential_helper)
        print('Application credential issued and scope verified. Enroll credentials.json into its exact OpenBao record using the bounded writer; never deliver the operator credential to the host.')
    except OperationError as error:
        parser.exit(1, str(error) + '. No credential contents displayed.\n')
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError):
        parser.exit(1, 'Publisher issuance failed. Preserve any custody directory and inspect the account before an explicit retry. No secret diagnostics displayed.\n')


if __name__ == '__main__':
    main()
