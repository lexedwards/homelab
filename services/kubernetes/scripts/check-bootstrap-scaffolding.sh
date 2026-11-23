#!/usr/bin/env bash
set -euo pipefail
umask 077
source_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
cleanup() {
  status=$?
  if (( status != 0 )); then
    printf 'Scaffolding fixture failed: %s\n' "${case:-setup}" >&2
    if [[ -f ${fixture:-}/stderr ]]; then cat "$fixture/stderr" >&2; fi
  fi
  rm -rf -- "$work"
}
trap cleanup EXIT
openssl req -x509 -newkey ed25519 -nodes -days 1 -subj /CN=bootstrap-fixture \
  -keyout "$work/key.pem" -out "$work/ca.pem" >/dev/null 2>&1

for case in absent rpm-scaffold empty-parent unknown-file local-snapshot snapshot-symlink db-symlink unsafe-directory partial-etcd tls-material appeared-during-download; do
  fixture="$work/$case"
  mkdir -p "$fixture/data" "$fixture/state" "$fixture/config"
  chmod 0700 "$fixture/state"
  printf '%s\n' '{}' > "$fixture/config/bootstrap-access.json"
  printf '%s\n' '{"with-node-id":true,"tls-san":["api.example.invalid"]}' > "$fixture/config/config.yaml"
  bwrap --unshare-all --uid 0 --gid 0 --clearenv \
    --setenv PATH /usr/bin --setenv HOME /nonexistent --setenv CASE "$case" \
    --ro-bind / / --proc /proc --dev /dev --tmpfs /tmp --tmpfs /etc --tmpfs /var/lib \
    --ro-bind "$source_directory" /tmp/source --ro-bind "$work/ca.pem" /tmp/ca.pem \
    --bind "$fixture/config" /etc/rancher/rke2 --bind "$fixture/data" /var/lib/rancher/rke2 \
    --bind "$fixture/state" /var/lib/kubernetes-bootstrap --chdir /tmp/source \
    /usr/bin/python3 -B - <<'PY' > "$fixture/stdout" 2> "$fixture/stderr"
import hashlib
import importlib.util
import json
import os
from pathlib import Path
from types import SimpleNamespace

from kubernetes_object_store import OperationError
from kubernetes_recovery import VERSION, token_hash

spec = importlib.util.spec_from_file_location('bootstrap', '/tmp/source/rke2-bootstrap.py')
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)
case = os.environ['CASE']
db = Path('/var/lib/rancher/rke2/server/db')
snapshots = db / 'snapshots'
if case != 'absent':
    snapshots.mkdir(parents=True)
if case == 'unknown-file':
    (db / 'unknown').write_text('preserve')
elif case == 'local-snapshot':
    (snapshots / 'retained.zip').write_text('preserve')
elif case == 'snapshot-symlink':
    snapshots.rmdir()
    snapshots.symlink_to('/tmp')
elif case == 'db-symlink':
    snapshots.rmdir()
    db.rmdir()
    db.symlink_to('/tmp')
elif case == 'unsafe-directory':
    db.chmod(0o777)
elif case == 'partial-etcd':
    (db / 'etcd').mkdir()
elif case == 'tls-material':
    Path('/var/lib/rancher/rke2/server/tls').mkdir()
elif case == 'empty-parent':
    snapshots.rmdir()

token = 'synthetic-fixture-server-password'
known = {'cluster_uid': '11111111-2222-4333-8444-555555555555',
         'ca_certificate': Path('/tmp/ca.pem').read_text(),
         'rke2_version': VERSION, 'token_hash': token_hash(token)}
storage = {'endpoint': 'https://s3.example.invalid', 'region': 'us-east-1'}
config = {'cluster_name': 'test-cluster', 'api_server': 'https://api.example.invalid:6443',
          'registration_server': 'https://api.example.invalid:9345',
          'backup': dict(storage, bucket='test-cluster-backups'),
          'publication': dict(storage, bucket='test-cluster-configuration')}
records = {'config_path': config, 'identity_path': known, 'server_token_path': {'server_token': token},
           's3_secret_path': {'access_key_id': 'synthetic', 'secret_access_key': 'synthetic'}}

class Reader:
    enrollment = {'cluster_name': 'test-cluster'}
    def __init__(self, *args): pass
    def read(self, field): return records[field]
    def close(self): pass

class Store:
    def __init__(self, *args): pass
    def request(self, *args):
        return 200, '', b'<ListBucketResult><Contents><Key>snapshots/homelab-scheduled-test-node-1790000000.zip</Key></Contents><IsTruncated>false</IsTruncated></ListBucketResult>'
    def head(self, *args):
        return 200, {'token_hash': token_hash(token), 'node_name': 'test-node', 'etag': '"' + 'a' * 32 + '"', 'size': '4'}
    def download(self, path, destination, size, headers=()):
        destination.write_bytes(b'test')
        if case == 'appeared-during-download': (db / 'unexpected').write_text('preserve')
        return {'size': 4, 'sha256': hashlib.sha256(b'test').hexdigest()}

native_calls = []
def native(args, **kwargs):
    native_calls.append(args)
    assert '--cluster-reset' in args and kwargs['env']['RKE2_TOKEN'] == token
    return SimpleNamespace(returncode=1)

bootstrap.BootstrapReader = Reader
bootstrap.NativeS3 = Store
bootstrap.endpoint_available = lambda *args: False
bootstrap.check_native = lambda: None
bootstrap.subprocess.run = native
try:
    bootstrap.execute(bootstrap.ACCESS, bootstrap.APPROLE)
except OperationError:
    pass
else:
    raise AssertionError('Synthetic failed native reset must not report successful bootstrap')
expected = case in ['absent', 'empty-parent', 'rpm-scaffold']
assert bool(native_calls) == expected, case
if expected:
    assert json.loads((bootstrap.STATE / 'restore-result.json').read_text()) == {'successful': False, 'returncode': 1}
    if case == 'rpm-scaffold': assert snapshots.is_dir() and not list(snapshots.iterdir())
else:
    assert not (bootstrap.STATE / 'restore-started.json').exists()
    for path in [db / 'unknown', snapshots / 'retained.zip', db / 'unexpected']:
        if path.exists(): assert path.read_text() == 'preserve'
print(case + ': native reset boundary and preservation verified')
PY
done
printf '%s\n' 'Empty native scaffolding reaches the reset boundary; unknown/nonempty/unsafe/partial paths and appeared data remain blocked. Isolated filesystem and external-I/O fixtures only.'
