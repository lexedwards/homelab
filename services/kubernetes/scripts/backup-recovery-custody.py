#!/usr/bin/env python3
import argparse
import importlib.util
import json
import os
from pathlib import Path
import stat


spec = importlib.util.spec_from_file_location('etcd_backup', Path(__file__).with_name('etcd-backup.py'))
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


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
        backup.require(args.independent_copies_confirmed, 'Independently recovered copies must be confirmed')
        backup.require(Path(args.server_token_file).resolve() != (backup.DATA / 'server/token').resolve(),
                       'Use an independently recovered token copy, not the live server token')
        target = backup.validate_target(backup.private_json(args.config))
        credentials = backup.validate_credentials(backup.private_json(args.credentials_file))
        token_hash = backup.server_token_hash(backup.private_text(args.server_token_file))
        custody = backup.private_json(args.previous) if args.previous else {
            'cluster_uid': target['cluster_uid'], 'server_token_hashes': [],
            'backup_credential_sha256': '', 'independent_copies_confirmed': False,
        }
        backup.require(custody['cluster_uid'] == target['cluster_uid'], 'Previous custody belongs to a different cluster')
        custody['server_token_hashes'] = sorted(set(custody['server_token_hashes'] + [token_hash]))
        custody['backup_credential_sha256'] = backup.credential_hash(credentials)
        custody['independent_copies_confirmed'] = True
        backup.validate_custody(target, credentials, custody)
        parent = Path(args.output).parent.stat()
        backup.require(parent.st_uid == os.geteuid() and not stat.S_IMODE(parent.st_mode) & 0o022,
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
