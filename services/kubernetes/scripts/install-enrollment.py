#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from kubernetes_object_store import OperationError, private_json, require
from kubernetes_recovery import access, digest, save


def main():
    parser = argparse.ArgumentParser(description='Install non-secret enrollment metadata over verified SSH, independently of VM assets.')
    parser.add_argument('purpose', choices=['bootstrap', 'publication'])
    parser.add_argument('sha256')
    args = parser.parse_args()
    require(os.geteuid() == 0, 'Enrollment installation requires root')
    raw = sys.stdin.buffer.read(65537)
    require(len(raw) <= 65536, 'Enrollment document too large')
    value = json.loads(raw)
    require(digest(value) == args.sha256, 'Enrollment document does not match the operator fingerprint')
    directory = Path('/etc/rancher/rke2')
    require(not any(p.is_symlink() for p in [directory, *directory.parents]) and directory.stat().st_uid == 0 and
            not directory.stat().st_mode & 0o022, 'Enrollment directory must remain root-owned and protected')
    if args.purpose == 'bootstrap':
        access(value)
        credential = directory / 'bootstrap-approle.json'
        updates = {directory / 'bootstrap-access.json': value}
        role_id = value['role_id']
    else:
        require(set(value) == {'openbao', 'publication'}, 'Unexpected publication configuration fields')
        from importlib.util import module_from_spec, spec_from_file_location
        spec = spec_from_file_location('publisher', Path(__file__).with_name('publish-kubeconfig.py'))
        publisher = module_from_spec(spec)
        spec.loader.exec_module(publisher)
        publisher.target(value['publication'])
        require(value['openbao']['reader_policy'] == value['openbao']['role_name'] + '-read', 'Invalid publication reader association')
        credential = directory / 'publication-approle.json'
        role_id = value['openbao']['role_id']
        updates = {directory / 'publication-openbao.json': value['openbao'], directory / 'publication.json': value['publication']}
    if credential.exists() or credential.is_symlink():
        require(private_json(credential)['role_id'] == role_id, 'Existing AppRole differs; no credential rotation or configuration overwrite')
    for destination in updates:
        if destination.exists() or destination.is_symlink():
            private_json(destination)
    for destination, document in updates.items():
        save(destination, document)
    result = subprocess.run(['restorecon', '-F', *map(str, updates)], capture_output=True, timeout=15)
    require(result.returncode == 0, 'Enrollment file labeling failed; activation remains blocked')
    print('Non-secret enrollment metadata installed. No VM asset, RKE2 configuration or datastore changed.')


if __name__ == '__main__':
    os.umask(0o077)
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError):
        sys.exit('Enrollment installation failed; no secret diagnostics. Inspect protected inputs before activation.')
