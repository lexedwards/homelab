#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from kubernetes_object_store import private_bytes, private_json
from kubernetes_recovery import access, digest


parser = argparse.ArgumentParser(description='Introduce OpenBao access over verified SSH, outside VM state/cloud-init. No lifecycle or snapshot selector.')
parser.add_argument('--enrollment', required=True)
parser.add_argument('--known-hosts', required=True)
parser.add_argument('--target', required=True)
parser.add_argument('--issuer-file', help='Private exact-role wrapped issuer token; unnecessary for an already-enrolled matching host.')
args = parser.parse_args()
try:
    document = access(private_json(args.enrollment))
    environment = {key: value for key, value in os.environ.items() if key not in ['BAO_TOKEN', 'VAULT_TOKEN'] and not key.startswith('AWS_')}
    environment.update(BAO_ADDR=document['address'], BAO_AUTH_MOUNT=document['auth_mount'],
                       BAO_TOKEN=private_bytes(args.issuer_file).decode().strip() if args.issuer_file else '',
                       PUBLICATION_ROLE=document['role_name'], CONTROL_PLANE_CREDENTIAL_HELPER='bootstrap-credentials',
                       CONTROL_PLANE_SSH_TARGET=args.target, CONTROL_PLANE_KNOWN_HOSTS=args.known_hosts,
                       PUBLICATION_CONFIG_SHA256=digest(document), PUBLICATION_CONFIGURATION=json.dumps(document))
    result = subprocess.run(['bash', str(Path(__file__).with_name('enroll-control-plane.sh'))], env=environment,
                            capture_output=True, timeout=1100)
    if result.returncode:
        raise ValueError('Enrollment/activation failed; preserve host evidence and inspect native unit status')
    print('OpenBao enrollment completed independently of VM installation assets.')
except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError):
    sys.exit('Bootstrap enrollment failed; no secret diagnostics or VM replacement.')
