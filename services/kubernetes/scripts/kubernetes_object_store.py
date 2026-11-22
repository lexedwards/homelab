import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
from urllib.parse import quote, urlsplit


class OperationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise OperationError(message)


def private_bytes(path, limit=65536):
    path = Path(path)
    require(not any(item.is_symlink() for item in [path, *path.parents]), 'Private input must not use symlinks')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as source:
        info = os.fstat(source.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and not stat.S_IMODE(info.st_mode) & 0o077,
                'Private input must be an owned private regular file')
        value = source.read(limit + 1)
    require(0 < len(value) <= limit, 'Private input size is invalid')
    return value


def private_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'Duplicate JSON field')
            result[key] = value
        return result

    result = json.loads(private_bytes(path), object_pairs_hook=unique)
    require(isinstance(result, dict), 'Private JSON input must be an object')
    return result


def https_origin(value):
    require(isinstance(value, str), 'HTTPS origin must be a string')
    parsed = urlsplit(value)
    require(parsed.scheme == 'https' and parsed.hostname and not parsed.username and not parsed.password and
            parsed.path in ['', '/'] and not parsed.query and not parsed.fragment and
            re.fullmatch(r'[A-Za-z0-9.-]+(?::[0-9]{1,5})?', parsed.netloc) and
            0 < (parsed.port or 443) <= 65535, 'A verified HTTPS origin without inline credentials is required')
    return value.rstrip('/')


def object_path(bucket, key):
    require(isinstance(bucket, str) and re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', bucket), 'Invalid bucket name')
    require(isinstance(key, str) and 0 < len(key) <= 1024 and
            all(part not in ['', '.', '..'] for part in key.split('/')), 'Invalid object key')
    return '/' + bucket + '/' + quote(key, safe='/')


def credentials(value):
    require(set(value) == {'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY'}, 'Expected the application S3 credential pair only')
    require(isinstance(value['AWS_ACCESS_KEY_ID'], str) and
            re.fullmatch(r'[A-Za-z0-9_-]{3,128}', value['AWS_ACCESS_KEY_ID']), 'Invalid application access-key format')
    require(isinstance(value['AWS_SECRET_ACCESS_KEY'], str) and
            re.fullmatch(r'[!-~]{8,1024}', value['AWS_SECRET_ACCESS_KEY']), 'Invalid application secret-key format')
    return value


class NativeS3:
    def __init__(self, endpoint, region, identity):
        self.endpoint = https_origin(endpoint)
        require(isinstance(region, str) and re.fullmatch(r'[a-z0-9-]+', region), 'Invalid S3 region')
        self.region = region
        self.identity = credentials(identity)

    def request(self, method, path, data=b'', headers=()):
        require(method in ['GET', 'PUT'] and path.startswith('/') and not path.startswith('//') and
                '\r' not in path and '\n' not in path, 'Unsupported object-store request')
        require(isinstance(data, bytes) and len(data) <= 131072, 'Request payload is too large')
        settings = {
            'url': self.endpoint + path,
            'request': method,
            'aws-sigv4': 'aws:amz:' + self.region + ':s3',
            'user': self.identity['AWS_ACCESS_KEY_ID'] + ':' + self.identity['AWS_SECRET_ACCESS_KEY'],
            'proto': '=https',
            'connect-timeout': '10',
            'max-time': '60',
            'max-filesize': '131072',
        }
        lines = [key + ' = ' + json.dumps(value) for key, value in settings.items()]
        lines += ['silent', 'show-error', 'header = ' + json.dumps('x-amz-content-sha256: ' + hashlib.sha256(data).hexdigest())]
        for header in headers:
            require(isinstance(header, str) and '\r' not in header and '\n' not in header, 'Invalid request header')
            lines.append('header = ' + json.dumps(header))
        descriptor = None
        try:
            if method == 'PUT':
                descriptor = os.memfd_create('kubernetes-object-request')
                os.fchmod(descriptor, 0o600)
                os.write(descriptor, data)
                os.lseek(descriptor, 0, os.SEEK_SET)
                lines.append('data-binary = ' + json.dumps('@/proc/' + str(os.getpid()) + '/fd/' + str(descriptor)))
            arguments = ['curl', '-q', '--config', '-', '--write-out', '\n%{http_code}\n%header{etag}']
            response = subprocess.run(arguments, input=('\n'.join(lines) + '\n').encode(),
                                      capture_output=True, timeout=75)
            require(response.returncode == 0, 'Verified HTTPS/SigV4 request failed; no credentials or child diagnostics displayed')
        finally:
            if descriptor is not None:
                os.close(descriptor)
        body, status, etag = response.stdout.rsplit(b'\n', 2)
        require(re.fullmatch(rb'[0-9]{3}', status) is not None, 'Invalid HTTP result')
        return int(status), etag.decode('ascii'), body
