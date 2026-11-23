#!/usr/bin/env bash
set -euo pipefail
umask 077
command -v bwrap >/dev/null
source_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
service_directory=$(dirname "$source_directory")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

new_case() {
  case_directory="$work/$1"
  mkdir -p "$case_directory/data" "$case_directory/state" "$case_directory/config"
  chmod 0700 "$case_directory/state"
}

run_case() {
  bwrap --unshare-all --uid 0 --gid 0 --clearenv \
    --setenv PATH /usr/bin --setenv HOME /nonexistent --setenv LANG C.UTF-8 \
    --ro-bind / / --proc /proc --dev /dev --tmpfs /tmp --tmpfs /etc --tmpfs /var/lib \
    --ro-bind "$source_directory" /tmp/source --chdir /tmp/source \
    --bind "$case_directory/config" /etc/rancher/rke2 \
    --bind "$case_directory/data" /var/lib/rancher/rke2 \
    --bind "$case_directory/state" /var/lib/kubernetes-bootstrap \
    /usr/bin/python3 -B /tmp/source/rke2-bootstrap.py --execute "$@" \
    > "$case_directory/stdout" 2> "$case_directory/stderr"
}

new_case unenrolled
if run_case; then exit 1; fi
grep -q 'Waiting for verified-SSH OpenBao enrollment' "$case_directory/stderr"

new_case initialized
mkdir -p "$case_directory/data/server/db/etcd/member/snap"
printf '%s\n' 'synthetic-database-must-not-change' > "$case_directory/data/server/db/etcd/member/snap/db"
before=$(sha256sum "$case_directory/data/server/db/etcd/member/snap/db")
run_case --enrollment /absent-config --approle-file /absent-credential
grep -q 'Initialized datastore preserved' "$case_directory/stdout"
[[ $(sha256sum "$case_directory/data/server/db/etcd/member/snap/db") == "$before" ]]

new_case partial
mkdir -p "$case_directory/data/server/db/etcd"
printf '%s\n' 'preserve-partial-data' > "$case_directory/data/server/db/etcd/partial"
if run_case; then exit 1; fi
grep -q 'Existing partial datastore requires inspection' "$case_directory/stderr"
[[ $(< "$case_directory/data/server/db/etcd/partial") == preserve-partial-data ]]

for state in empty-tree file symlink unsafe-directory; do
  new_case "$state"
  directory="$case_directory/data/server/db/scaffold/nested"
  mkdir -p "$directory"
  case "$state" in
    file) printf '%s\n' 'preserve' > "$directory/data" ;;
    symlink) ln -s /tmp "$directory/link" ;;
    unsafe-directory) chmod 0777 "$directory" ;;
  esac
  if run_case; then exit 1; fi
  if [[ $state == empty-tree ]]; then
    grep -q 'Waiting for verified-SSH OpenBao enrollment' "$case_directory/stderr"
  else
    grep -q 'Existing partial datastore requires inspection' "$case_directory/stderr"
  fi
  if [[ $state == file ]]; then [[ $(< "$directory/data") == preserve ]]; fi
done

new_case incomplete-reset
mkdir -p "$case_directory/data/server/db/etcd/member/snap"
printf '%s\n' 'preserve-failed-reset' > "$case_directory/data/server/db/etcd/member/snap/db"
printf '%s\n' '{"intent_sha256":"test","snapshot_sha256":"test"}' > "$case_directory/state/restore-started.json"
if run_case; then exit 1; fi
grep -q 'Incomplete or inconsistent restore attempt blocks startup' "$case_directory/stderr"

for state in completed-reset missing-restored-data; do
  new_case "$state"
  printf '%s\n' '{"intent_sha256":"test","snapshot_sha256":"test"}' > "$case_directory/state/restore-started.json"
  cp "$case_directory/state/restore-started.json" "$case_directory/state/restore-complete.json"
  printf '%s\n' '{"successful":true,"returncode":0}' > "$case_directory/state/restore-result.json"
  if [[ $state == completed-reset ]]; then
    mkdir -p "$case_directory/data/server/db/etcd/member/snap"
    printf '%s\n' 'do-not-reset-again' > "$case_directory/data/server/db/etcd/member/snap/db"
    run_case --enrollment /absent-config --approle-file /absent-credential
    grep -q 'Initialized datastore preserved' "$case_directory/stdout"
  else
    if run_case; then exit 1; fi
    grep -q 'Previously restored datastore is missing' "$case_directory/stderr"
  fi
done

cat > "$work/base.tfvars.json" <<'JSON'
{"proxmox_endpoint":"https://proxmox.example.invalid","proxmox_ssh_username":"operator","technitium_server_url":"https://dns.example.invalid","proxmox_nodes":{"compute":{"ssh_address":"compute.example.invalid","snippet_datastore_id":"test-snippets","vm_datastore_id":"test-disks","vm_bridge":"test-bridge"}},"template":{"vm_id":900,"node_name":"compute"},"control_plane":{"vm_id":901,"name":"test-control-plane"},"primary_vlan_id":100,"cloud_user":"operator","cloud_ssh_public_keys":["ssh-ed25519 dGVzdA=="],"api_dns":{"zone":"example.invalid","name":"api.example.invalid"},"cluster_networks":{"pods":"198.18.0.0/16","services":"198.19.0.0/16"}}
JSON
jq '. + {publication_enrollment_revision:"changed",publication_ssh_known_hosts_file:"./tests/publication.tftest.hcl",publication_access:{address:"https://bao.example.invalid",auth_mount:"approle",role_name:"kubernetes-test-cluster-kubeconfig",role_id:"11111111-2222-4333-8444-555555555555",reader_policy:"kubernetes-test-cluster-kubeconfig-read",secret_path:"secret/data/kubernetes/test/publication",publication:{endpoint:"https://s3.example.invalid",bucket:"test-cluster-configuration",region:"us-east-1",cluster_name:"test-cluster",cluster_uid:"11111111-2222-4333-8444-555555555555",api_server:"https://api.example.invalid:6443"}}}' \
  "$work/base.tfvars.json" > "$work/enrolled.tfvars.json"
jq '. + {bootstrap_enrollment_revision:"changed-bootstrap",bootstrap_ssh_known_hosts_file:"./tests/publication.tftest.hcl",bootstrap_access:{address:"https://bao.example.invalid",auth_mount:"approle",cluster_name:"test-server",role_name:"kubernetes-test-server-bootstrap",role_id:"11111111-2222-4333-8444-555555555555",reader_policy:"kubernetes-test-server-bootstrap-read",identity_token_role:"kubernetes-test-server-identity",identity_writer_policy:"kubernetes-test-server-identity",config_path:"secret/data/kubernetes/test/config",identity_path:"secret/data/kubernetes/test/identity",server_token_path:"secret/data/kubernetes/test/server-token/0123456789ab",s3_secret_path:"secret/data/kubernetes/test/backup-credentials",publication_secret_path:"secret/data/kubernetes/test/publication-credentials"}}' \
  "$work/base.tfvars.json" > "$work/bootstrap-enrolled.tfvars.json"
jq '. + {snippet_namespace:"test-isolated",control_plane_protection:false}' \
  "$work/base.tfvars.json" > "$work/isolated.tfvars.json"
for input in base enrolled bootstrap-enrolled isolated; do
  printf '%s\n' 'base64encode(nonsensitive(local.control_plane_cloud_config))' | \
    tofu -chdir="$service_directory" console -state="$work/console.tfstate" -var-file="$work/$input.tfvars.json" \
    > "$work/$input.rendered"
done
cmp "$work/base.rendered" "$work/enrolled.rendered"
cmp "$work/base.rendered" "$work/bootstrap-enrolled.rendered"
cmp "$work/base.rendered" "$work/isolated.rendered"
PYTHONPATH="$source_directory" python3 -B - <<'PY'
import urllib.error
import importlib.util
import base64
import json
from pathlib import Path
import tempfile
from subprocess import CompletedProcess
import kubernetes_recovery as recovery
from kubernetes_object_store import OperationError

def refuses(operation, message):
    try:
        operation()
    except OperationError as error:
        assert message in str(error), str(error)
    else:
        raise AssertionError('Unsafe discovery result was accepted')

class Store:
    def __init__(self, responses):
        self.responses = iter(responses)
    def request(self, *args):
        return next(self.responses)
    def head(self, path):
        return 200, {'token_hash': recovery.token_hash('synthetic-password'), 'node_name': 'test-server',
                     'size': '1024', 'etag': '"' + 'a' * 32 + '"'}

for prefix in ['etcd-snapshot', 'homelab-scheduled']:
    key = 'snapshots/' + prefix + '-test-server-1795425179.zip'
    inventory = ('<ListBucketResult><Contents><Key>' + key + '</Key></Contents><IsTruncated>false</IsTruncated></ListBucketResult>').encode()
    point = recovery.latest_snapshot(Store([(200, '', inventory)]), {'backup': {'bucket': 'test-cluster-backups'}},
        {'token_hash': recovery.token_hash('synthetic-password')}, 'synthetic-password')
    assert point['key'] == key and point['timestamp'] == 1795425179

config = {'api_server': 'https://api.example.invalid:6443', 'registration_server': 'https://api.example.invalid:9345',
          'backup': {'endpoint': 'https://s3.example.invalid', 'region': 'us-east-1', 'bucket': 'test-cluster-backups'}}
with tempfile.TemporaryDirectory() as directory:
    original = recovery.CONFIG, recovery.OVERLAY, recovery.SNAPSHOTS, recovery.TOKEN
    recovery.CONFIG = Path(directory) / 'config.yaml'
    recovery.OVERLAY = Path(directory) / 'config.yaml.d/90-bootstrap.yaml'
    recovery.SNAPSHOTS = recovery.OVERLAY.with_name('80-snapshots.yaml')
    recovery.TOKEN = Path(directory) / 'server-token'
    recovery.install_token('synthetic-password')
    token_before = recovery.TOKEN.read_bytes()
    recovery.CONFIG.write_text('{"with-node-id":true,"tls-san":["api.example.invalid"]}')
    recovery.CONFIG.chmod(0o600)
    recovery.configuration('restore', config)
    native = json.loads(recovery.SNAPSHOTS.read_text())
    assert native == {'etcd-snapshot-schedule-cron': '0 */6 * * *', 'etcd-snapshot-retention': 5,
                      'etcd-s3-retention': 56, 'etcd-snapshot-compress': True, 'etcd-s3': True,
                      'etcd-s3-config-secret': 'rke2-etcd-snapshot-s3-config'}
    assert recovery.snapshot_configuration(config) is False
    customised = dict(config, snapshots={'etcd-snapshot-schedule-cron': '0 */4 * * *',
                                       'etcd-snapshot-retention': 6, 'etcd-s3-retention': 84})
    assert recovery.snapshot_configuration(customised) is True
    assert json.loads(recovery.SNAPSHOTS.read_text())['etcd-s3-retention'] == 84
    recovery.install_token('synthetic-password')
    refuses(lambda: recovery.install_token('different-password'), 'Existing server token differs')
    assert recovery.TOKEN.read_bytes() == token_before
    recovery.SNAPSHOTS.unlink()
    recovery.OVERLAY.unlink()
    recovery.configuration('join', config)
    assert not recovery.SNAPSHOTS.exists()
    recovery.CONFIG, recovery.OVERLAY, recovery.SNAPSHOTS, recovery.TOKEN = original

pair = {'access_key_id': 'synthetic-access', 'secret_access_key': 'synthetic-secret'}
desired = recovery.snapshot_secret(config, pair)
assert desired['type'] == 'etcd.k3s.cattle.io/s3-config-secret'
assert base64.b64decode(desired['data']['etcd-s3-bucket']) == b'test-cluster-backups'
assert base64.b64decode(desired['data']['etcd-s3-retention']) == b'56'
assert 'server_token' not in desired['data']
original_run = recovery.subprocess.run
requests = []
existing = None
def kubectl(arguments, **kwargs):
    if 'get' in arguments:
        return CompletedProcess(arguments, 0, stdout=json.dumps(existing).encode() if existing else b'')
    assert arguments[-2:] == ['-f', '-']
    requests.append((arguments[-3], json.loads(kwargs['input'])))
    return CompletedProcess(arguments, 0, stdout=b'')
try:
    recovery.subprocess.run = kubectl
    recovery.enroll_snapshot_secret(config, pair)
    assert requests == [('create', desired)]
    existing = dict(desired, metadata=dict(desired['metadata'], resourceVersion='7'))
    recovery.enroll_snapshot_secret(config, pair)
    assert len(requests) == 1
    recovery.enroll_snapshot_secret(config, dict(pair, secret_access_key='renewed-synthetic-secret'))
    assert requests[-1][0] == 'replace' and requests[-1][1]['metadata']['resourceVersion'] == '7'
    existing = dict(existing, metadata={'name': recovery.SNAPSHOT_SECRET, 'resourceVersion': '8'})
    refuses(lambda: recovery.enroll_snapshot_secret(config, pair), 'another owner')
    assert len(requests) == 2
finally:
    recovery.subprocess.run = original_run
refuses(lambda: recovery.snapshot_options(dict(config, snapshots={'etcd-s3-access-key': 'not-configuration'})), 'Unexpected native snapshot')
refuses(lambda: recovery.snapshot_options(dict(config, snapshots={'etcd-s3-retention': -1})), 'nonnegative')

spec = importlib.util.spec_from_file_location('publisher', Path(recovery.__file__).with_name('publish-kubeconfig.py'))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
publication = publisher.target({'endpoint': 'https://s3.example.invalid', 'region': 'us-east-1',
    'bucket': 'test-cluster-configuration', 'cluster_name': 'test-cluster',
    'cluster_uid': '11111111-2222-4333-8444-555555555555', 'api_server': 'https://api.example.invalid:6443',
    'initializer': True, 'rke2_config_sha256': 'a' * 64})
class PublisherStore:
    def request(self, method, path, data=b'', headers=()):
        assert path == '/test-cluster-configuration/kubeconfig.yaml', path
        if method == 'PUT':
            assert 'If-None-Match: *' in headers
        return 200, '"synthetic"', b'synthetic-kubeconfig'
publisher.publish(PublisherStore(), publication, b'synthetic-kubeconfig', None)
spec = importlib.util.spec_from_file_location('issuer', Path(recovery.__file__).with_name('issue-publication-credentials.py'))
issuer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(issuer)
scope = {'endpoint': 'https://s3.example.invalid', 'region': 'us-east-1', 'bucket': 'test-cluster-configuration',
         'cluster_name': 'test-cluster', 'key': 'kubeconfig.yaml', 'policy': {'Version': '2012-10-17', 'Statement': [
             {'Effect': 'Allow', 'Action': ['s3:GetObject', 's3:PutObject'],
              'Resource': ['arn:aws:s3:::test-cluster-configuration/kubeconfig.yaml']}]}}
issuer.publisher(scope)
refuses(lambda: issuer.publisher(dict(scope, bucket='other-cluster-configuration')), 'dedicated named-cluster bucket')
refuses(lambda: issuer.publisher(dict(scope, key='rke2/*/kubeconfig.yaml')), 'exact configuration key')
config = {'backup': {'bucket': 'backup'}}
empty = (200, '', b'<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>')
known = {'cluster_uid': '11111111-2222-4333-8444-555555555555',
         'token_hash': recovery.token_hash('synthetic-password')}
refuses(lambda: recovery.latest_snapshot(Store([empty]), config, known, 'synthetic-password'),
        'new-cluster creation is forbidden')
refuses(lambda: recovery.latest_snapshot(Store([(403, '', b'')]), config, None, 'synthetic-password'),
        'absence is not established')
history = (200, '', b'<ListVersionsResult><DeleteMarker/><IsTruncated>false</IsTruncated></ListVersionsResult>')
refuses(lambda: recovery.latest_snapshot(Store([empty, history]), config, None, 'synthetic-password'),
        'history prevents')
clear = (200, '', b'<ListVersionsResult><IsTruncated>false</IsTruncated></ListVersionsResult>')
assert recovery.latest_snapshot(Store([empty, clear]), config, None, 'synthetic-password') is None

class Endpoint:
    reason = ConnectionRefusedError()
    def open(self, *args, **kwargs):
        raise urllib.error.URLError(self.reason)

endpoint = Endpoint()
recovery.urllib.request.build_opener = lambda *args: endpoint
config = {'registration_server': 'https://api.example.invalid:9345'}
assert recovery.endpoint_available(config, None) is False
for reason in [TimeoutError(), OSError('DNS unavailable'), recovery.ssl.SSLError()]:
    endpoint.reason = reason
    refuses(lambda: recovery.endpoint_available(config, None), 'uncertain')
print('Discovery boundary fixtures passed: authenticated absence, retained history, missing known backup and transport uncertainty.')
PY
printf '%s\n' 'Startup guards passed in isolated namespaces. Native OpenTofu rendering is byte-identical across enrollment changes. No infrastructure operation executed.'
