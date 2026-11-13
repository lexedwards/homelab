#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import re
import stat
import sys
import urllib.error
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        raise ValueError('OpenBao credential requests must not redirect')


def read_private(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor) as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise ValueError('Input must be an operator-owned private regular file')
        value = source.read(65537)
        if not value or len(value) > 65536:
            raise ValueError('Private input is empty or exceeds 64 KiB')
        return value


def load_enrollment(path):
    enrollment = json.loads(read_private(path))
    if not re.fullmatch(r'https://[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::[0-9]{1,5})?', enrollment['address']):
        raise ValueError('Enrollment needs a verified HTTPS origin without credentials, path or query')
    for field in ['token_role', 'deployment_policy']:
        if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,125}', enrollment[field]):
            raise ValueError('Enrollment needs exact deployment role/policy names')
    if enrollment['token_role'] != enrollment['deployment_policy']:
        raise ValueError('Deployment role and policy must belong to the same enrollment')
    return enrollment


def request(enrollment, token, path, data):
    message = urllib.request.Request(enrollment['address'] + '/v1/' + path, method='POST',
                                     data=json.dumps(data).encode(),
                                     headers={'X-Vault-Token': token, 'Content-Type': 'application/json'})
    try:
        with urllib.request.build_opener(NoRedirect).open(message, timeout=30) as response:
            body = response.read()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as error:
        code = error.code
        error.close()
        raise ValueError(f'OpenBao rejected the operation (HTTP {code}); response body suppressed') from None
    except urllib.error.URLError:
        raise ValueError('OpenBao request failed; transport details suppressed') from None


def issue(enrollment, issuer_token, output):
    parent = Path(output).parent.stat()
    if parent.st_uid != os.getuid() or stat.S_IMODE(parent.st_mode) & 0o022:
        raise ValueError('Output directory must be operator-owned and not group/world-writable')
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    token = None
    try:
        with os.fdopen(descriptor, 'w') as destination:
            os.fchmod(destination.fileno(), 0o600)
            auth = request(enrollment, issuer_token, 'auth/token/create/' + enrollment['token_role'], {
                'policies': [enrollment['deployment_policy']], 'ttl': '900s',
                'renewable': False, 'no_default_policy': True,
            })['auth']
            token = auth['client_token']
            if (not isinstance(token, str) or not token or any(character.isspace() for character in token) or
                    auth['policies'] != [enrollment['deployment_policy']] or auth.get('identity_policies') or
                    auth['renewable'] or not 0 < auth['lease_duration'] <= 900):
                raise ValueError('Issued credential differs from its bounded deployment contract')
            destination.write(token + '\n')
    except BaseException:
        if isinstance(token, str) and token:
            try:
                request(enrollment, token, 'auth/token/revoke-self', {})
            except (ValueError, OSError):
                pass
        Path(output).unlink()
        raise


def write_record(enrollment, token, path, source):
    if path not in enrollment['secret_paths']:
        raise ValueError('Record is not declared by this service enrollment')
    content = source.read(1024 * 1024 + 1)
    if len(content) > 1024 * 1024:
        raise ValueError('Secret input exceeds 1 MiB')
    try:
        values = json.loads(content)
    except json.JSONDecodeError:
        raise ValueError('Secret input must be a JSON object; contents suppressed') from None
    if not isinstance(values, dict) or not values:
        raise ValueError('Secret input must be a nonempty JSON object')
    request(enrollment, token, path, {'data': values})


def main():
    parser = argparse.ArgumentParser(description='Issue a bounded service writer or populate an owned record without printing credentials/values. Never reads secret values.')
    parser.add_argument('--enrollment', required=True)
    parser.add_argument('--token-file', required=True)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('issue').add_argument('--output', required=True)
    commands.add_parser('write').add_argument('--secret-path', required=True)
    commands.add_parser('revoke')
    args = parser.parse_args()
    try:
        enrollment = load_enrollment(args.enrollment)
        token = read_private(args.token_file).strip()
        if not token or any(character.isspace() for character in token):
            raise ValueError('Credential file must contain one nonempty token')
        if args.command == 'issue':
            issue(enrollment, token, args.output)
        elif args.command == 'write':
            write_record(enrollment, token, args.secret_path, sys.stdin)
        else:
            request(enrollment, token, 'auth/token/revoke-self', {})
    except (ValueError, KeyError, TypeError, OSError):
        parser.exit(1, 'Service credential operation failed; credential/value details suppressed. Check private inputs, authorization and connectivity.\n')
    print('Service credential operation completed; no credential or secret value output.')


if __name__ == '__main__':
    main()
