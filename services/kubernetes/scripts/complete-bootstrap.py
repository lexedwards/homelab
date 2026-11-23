#!/usr/bin/env python3
import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from kubernetes_object_store import OperationError, private_bytes, private_json, require
from kubernetes_recovery import ACCESS, CONFIG, DATA, STATE, VERSION, BootstrapReader, check_native, enroll_snapshot_secret, identity, initialized, profile, save, snapshot_configuration, token_hash


def main():
    require(os.geteuid() == 0 and initialized(), 'Completion requires the initialized server')
    check_native()
    decision = private_json(STATE / 'decision.json') if (STATE / 'decision.json').exists() else {'role': 'existing'}
    if decision['role'] == 'join':
        print('Joining server: no kubeconfig publication or publication-credential read.')
        return
    with closing(BootstrapReader(private_json(ACCESS))) as reader:
        config = profile(reader.read('config_path'))
        require(config['cluster_name'] == reader.enrollment['cluster_name'], 'Runtime profile differs from the enrolled cluster name')
        known = identity(reader.read('identity_path'))
        result = subprocess.run(['/var/lib/rancher/rke2/bin/kubectl', '--kubeconfig=/etc/rancher/rke2/rke2.yaml',
                                 '--server=' + config['api_server'], '--insecure-skip-tls-verify=false', '--request-timeout=15s',
                                 'get', 'namespace', 'kube-system', '-o', 'json'], capture_output=True, timeout=20)
        require(result.returncode == 0, 'Stable API is not ready; completion will retry without restarting RKE2')
        uid = json.loads(result.stdout)['metadata']['uid']
        observed = {'cluster_uid': uid, 'ca_certificate': (DATA / 'server/tls/server-ca.crt').read_text(),
                    'rke2_version': VERSION, 'token_hash': token_hash(private_bytes(DATA / 'server/token').decode().strip())}
        if known:
            require(observed == known, 'Initialized cluster differs from independent OpenBao identity')
        else:
            require(decision['role'] == 'create', 'An existing cluster requires independent identity enrollment, not automatic adoption')
            reader.record_identity(observed)
        changed = snapshot_configuration(config)
        enroll_snapshot_secret(config, reader.read('s3_secret_path'))
        if changed:
            print('Native snapshot settings staged; an existing server needs a separately approved RKE2 restart to load them.')
        pair = reader.read('publication_secret_path')
        require(set(pair) == {'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY'}, 'Unexpected application publisher record')
        target = dict(config['publication'], cluster_name=config['cluster_name'], cluster_uid=uid, api_server=config['api_server'], initializer=True,
                      rke2_config_sha256=hashlib.sha256(private_bytes(CONFIG)).hexdigest())
        staged_pair = Path('/run/kubernetes-bootstrap/publication-credentials.json')
        staged_target = Path('/run/kubernetes-bootstrap/publication.json')
        save(staged_pair, pair)
        save(staged_target, target)
    result = subprocess.run(['/usr/bin/python3', '-B', '/usr/local/libexec/homelab/publish-kubeconfig.py', '--execute',
                             '--config', str(staged_target), '--credentials-file', str(staged_pair)],
                            capture_output=True, timeout=300)
    require(result.returncode == 0, 'Kubeconfig publication needs inspection or explicit refresh; RKE2 remains running')
    save(Path('/etc/rancher/rke2/publication-credentials.json'), pair)
    save(Path('/etc/rancher/rke2/publication.json'), target)
    print('Cluster identity verified; application-scoped kubeconfig publication completed.')


if __name__ == '__main__':
    os.umask(0o077)
    parser = argparse.ArgumentParser(description='Verify/record durable cluster identity and publish using application credentials, without restarting a healthy server.')
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    try:
        if args.execute:
            main()
        else:
            print('Plan only: no credential reads, API operations or writes.')
    except OperationError as error:
        sys.exit(str(error) + '. No secret diagnostics displayed.')
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError):
        sys.exit('Bootstrap completion failed; no healthy-server restart or secret diagnostics.')
