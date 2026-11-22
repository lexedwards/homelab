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
        return self._request(method, path, data, headers)

    def head(self, path):
        return self._request('HEAD', path, inspect=True, max_bytes=16 * 1024 ** 3)

    def _request(self, method, path, data=b'', headers=(), output=None, max_bytes=131072, timeout=60, inspect=False):
        require(method in ['GET', 'PUT', 'HEAD'] and path.startswith('/') and not path.startswith('//') and
                '\r' not in path and '\n' not in path, 'Unsupported object-store request')
        require(isinstance(data, bytes) and len(data) <= 131072, 'Request payload is too large')
        settings = {
            'url': self.endpoint + path,
            'request': method,
            'aws-sigv4': 'aws:amz:' + self.region + ':s3',
            'user': self.identity['AWS_ACCESS_KEY_ID'] + ':' + self.identity['AWS_SECRET_ACCESS_KEY'],
            'proto': '=https',
            'connect-timeout': '10',
            'max-time': str(timeout),
            'max-filesize': str(max_bytes),
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
            if inspect:
                arguments = ['curl', '-q', '--config', '-', '--head', '--output', '/dev/null', '--write-out',
                             '%{http_code}\n%header{etag}\n%header{x-amz-meta-rke2-token-hash}\n%header{x-amz-meta-rke2-node-name}\n%header{content-length}']
            if output is not None:
                arguments += ['--output', '/proc/' + str(os.getpid()) + '/fd/' + str(output)]
            response = subprocess.run(arguments, input=('\n'.join(lines) + '\n').encode(),
                                      capture_output=True, timeout=timeout + 15)
            require(response.returncode == 0, 'Verified HTTPS/SigV4 request failed; no credentials or child diagnostics displayed')
        finally:
            if descriptor is not None:
                os.close(descriptor)
        if inspect:
            status, etag, token, node, size = response.stdout.decode('ascii').split('\n')
            require(status.isdigit(), 'Invalid HTTP result')
            return int(status), {'etag': etag, 'token_hash': token, 'node_name': node, 'size': size}
        body, status, etag = response.stdout.rsplit(b'\n', 2)
        require(re.fullmatch(rb'[0-9]{3}', status) is not None, 'Invalid HTTP result')
        return int(status), etag.decode('ascii'), body

    def download(self, path, destination, max_bytes, headers=()):
        destination = Path(destination)
        require(isinstance(max_bytes, int) and 0 < max_bytes <= 16 * 1024 ** 3, 'Invalid snapshot download bound')
        require(not any(item.is_symlink() for item in [destination, *destination.parents]), 'Snapshot custody must not use symlinks')
        parent = destination.parent.stat()
        require(parent.st_uid == os.geteuid() and stat.S_ISDIR(parent.st_mode) and not parent.st_mode & 0o077,
                'Snapshot custody requires an owned private parent directory')
        descriptor = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        complete = False
        try:
            status, _, _ = self._request('GET', path, headers=headers, output=descriptor, max_bytes=max_bytes, timeout=600)
            require(status == 200, 'Snapshot GetObject failed (HTTP ' + str(status) + ')')
            os.fsync(descriptor)
            size = os.fstat(descriptor).st_size
            require(0 < size <= max_bytes, 'Downloaded snapshot size is invalid')
            os.lseek(descriptor, 0, os.SEEK_SET)
            checksum = hashlib.sha256()
            while data := os.read(descriptor, 1024 * 1024):
                checksum.update(data)
            complete = True
            return {'size': size, 'sha256': checksum.hexdigest()}
        finally:
            os.close(descriptor)
            if not complete:
                destination.unlink()
