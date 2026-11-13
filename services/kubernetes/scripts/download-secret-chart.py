#!/usr/bin/env python3
import base64
import hashlib
import json
import re
import sys
import urllib.request


def download(query):
    url, digest = query['url'], query['sha256']
    if not url.startswith('https://') or not re.fullmatch('[0-9a-f]{64}', digest):
        raise ValueError('A pinned HTTPS chart URL and SHA-256 are required')
    with urllib.request.urlopen(url, timeout=60) as response:
        content = response.read(8 * 1024 * 1024 + 1)
    if len(content) > 8 * 1024 * 1024:
        raise ValueError('Chart exceeds the 8 MiB download limit')
    if hashlib.sha256(content).hexdigest() != digest:
        raise ValueError('Downloaded chart checksum differs from the reviewed pin')
    return {'content': base64.b64encode(content).decode('ascii')}


if __name__ == '__main__':
    try:
        json.dump(download(json.load(sys.stdin)), sys.stdout)
    except (ValueError, KeyError, OSError) as error:
        print(f'Chart download failed: {error}', file=sys.stderr)
        sys.exit(1)
