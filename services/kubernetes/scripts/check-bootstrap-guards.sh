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
if run_case; then exit 1; fi
grep -q 'Existing partial datastore requires inspection' "$case_directory/stderr"

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
jq '. + {publication_enrollment_revision:"changed",publication_ssh_known_hosts_file:"./tests/publication.tftest.hcl",publication_access:{address:"https://bao.example.invalid",auth_mount:"approle",role_name:"kubernetes-11111111-2222-4333-8444-555555555555-kubeconfig",role_id:"11111111-2222-4333-8444-555555555555",reader_policy:"kubernetes-11111111-2222-4333-8444-555555555555-kubeconfig-read",secret_path:"secret/data/kubernetes/test/publication",publication:{endpoint:"https://s3.example.invalid",bucket:"test-configuration",region:"us-east-1",cluster_uid:"11111111-2222-4333-8444-555555555555",api_server:"https://api.example.invalid:6443"}}}' \
  "$work/base.tfvars.json" > "$work/enrolled.tfvars.json"
for input in base enrolled; do
  printf '%s\n' 'base64encode(nonsensitive(local.control_plane_cloud_config))' | \
    tofu -chdir="$service_directory" console -state="$work/console.tfstate" -var-file="$work/$input.tfvars.json" \
    > "$work/$input.rendered"
done
cmp "$work/base.rendered" "$work/enrolled.rendered"
PYTHONPATH="$source_directory" python3 -B - <<'PY'
import urllib.error
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
