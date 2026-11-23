#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ ${1:-} != --inside ]]; then
  : "${BAO_BINARY:?Set BAO_BINARY to a reviewed local OpenBao server binary}"
  source_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' EXIT
  cat > "$work/inputs.json" <<'JSON'
{"openbao_address":"https://localhost:18200","approle_mount":"approle","cluster_name":"test-cluster","records":{"config_path":"secret/data/kubernetes/test-cluster/profile","identity_path":"secret/data/kubernetes/test-cluster/identity","server_token_path":"secret/data/kubernetes/test-cluster/token","s3_secret_path":"secret/data/kubernetes/test-cluster/backup","publication_secret_path":"secret/data/kubernetes/test-cluster/publication"}}
JSON
  for policy in reader identity; do
    printf 'jsonencode(nonsensitive(local.%s_policy))\n' "$policy" | \
      tofu -chdir="$source_directory/../recovery" console -state="$work/console.tfstate" -var-file="$work/inputs.json" | \
      jq -er fromjson > "$work/$policy.hcl"
  done
  bwrap --unshare-all --uid 0 --gid 0 --clearenv --ro-bind / / --proc /proc --dev /dev --tmpfs /tmp \
    --bind "$work" /tmp/fixture --ro-bind "$source_directory" /tmp/source --ro-bind "$BAO_BINARY" /tmp/bao \
    --setenv PATH /tmp:/usr/bin --setenv HOME /tmp/fixture \
    /usr/bin/bash /tmp/source/check-bootstrap-authorization.sh --inside
  exit
fi

export BAO_ADDR=https://localhost:18200 BAO_TOKEN=synthetic-root
bao server -dev -dev-tls -dev-tls-cert-dir=/tmp/fixture -dev-root-token-id=synthetic-root \
  -dev-listen-address=127.0.0.1:18200 > /tmp/fixture/server.log 2>&1 &
server=$!
trap 'kill "$server"; wait "$server" || true' EXIT
for attempt in $(seq 1 100); do
  for certificate in /tmp/fixture/*-ca.pem; do
    if [[ -f $certificate ]]; then export BAO_CACERT="$certificate"; fi
  done
  if bao status >/dev/null 2>&1; then break; fi
  sleep 0.1
done
bao status >/dev/null
bao kv metadata put -cas-required=true secret/kubernetes/test-cluster/identity > /tmp/fixture/metadata-result
bao policy write kubernetes-test-cluster-bootstrap-read /tmp/fixture/reader.hcl > /tmp/fixture/policy-result
bao policy write kubernetes-test-cluster-identity /tmp/fixture/identity.hcl > /tmp/fixture/writer-result
bao write auth/token/roles/kubernetes-test-cluster-identity allowed_policies=kubernetes-test-cluster-identity \
  disallowed_policies=root,default,kubernetes-test-cluster-bootstrap-read orphan=false renewable=false \
  token_no_default_policy=true token_explicit_max_ttl=60 token_type=service > /tmp/fixture/token-role-result
bao auth enable approle > /tmp/fixture/auth-result
role=auth/approle/role/kubernetes-test-cluster-bootstrap
bao write "$role" token_policies=kubernetes-test-cluster-bootstrap-read token_no_default_policy=true \
  token_ttl=900 token_max_ttl=900 secret_id_num_uses=0 secret_id_ttl=0 > /tmp/fixture/role-result
role_id=$(bao read -field=role_id "$role/role-id")
bao write -format=json -f "$role/secret-id" | \
  jq --arg role "$role_id" '{role_id:$role,secret_id:.data.secret_id}' > /tmp/fixture/approle.json
jq --arg role "$role_id" '.records + {address:.openbao_address,auth_mount:.approle_mount,cluster_name:.cluster_name,
  role_name:"kubernetes-test-cluster-bootstrap",reader_policy:"kubernetes-test-cluster-bootstrap-read",role_id:$role,
  identity_token_role:"kubernetes-test-cluster-identity",identity_writer_policy:"kubernetes-test-cluster-identity"}' \
  /tmp/fixture/inputs.json > /tmp/fixture/enrollment.json
export SSL_CERT_FILE="$BAO_CACERT" PYTHONPATH=/tmp/source
python3 -B - <<'PY'
from contextlib import closing
import os
from pathlib import Path
from kubernetes_recovery import BootstrapReader, VERSION, token_hash
from kubernetes_object_store import OperationError, private_json

def denied(action):
    try:
        action()
    except OperationError:
        return
    raise AssertionError('Unsafe identity mutation was allowed')

with closing(BootstrapReader(private_json('/tmp/fixture/enrollment.json'), '/tmp/fixture/approle.json')) as reader:
    assert reader.read('identity_path') is None
    identity = {'cluster_uid': '11111111-2222-4333-8444-555555555555',
                'ca_certificate': Path(os.environ['SSL_CERT_FILE']).read_text(),
                'rke2_version': VERSION, 'token_hash': token_hash('synthetic-password')}
    path = reader.enrollment['identity_path']
    writer = reader.request('POST', 'auth/token/create/' + reader.enrollment['identity_token_role'], {
        'policies': [reader.enrollment['identity_writer_policy']], 'ttl': '60s', 'explicit_max_ttl': '60s',
        'renewable': False, 'no_default_policy': True})['auth']['client_token']
    for options in [None, {}, {'cas': 1}, {'cas': '1'}, {'cas': 0}]:
        payload = {'data': identity}
        if options is not None:
            payload['options'] = options
        denied(lambda: reader.request('POST', path, payload, token=writer))
    reader.record_identity(identity)
    assert reader.read('identity_path') == identity
    denied(lambda: reader.record_identity(identity))
    denied(lambda: reader.request('POST', path, {'options': {'cas': '1'}, 'data': identity}, token=writer))
    denied(lambda: reader.request('POST', path.replace('/data/', '/metadata/', 1), {'cas_required': False}, token=writer))
    denied(lambda: reader.request('DELETE', path, token=writer))
    denied(lambda: reader.request('POST', reader.enrollment['server_token_path'], {'data': {'server_token': 'different'}}, token=writer))
    denied(lambda: reader.request('POST', 'auth/token/create', {'policies': ['root']}))
    reader.request('POST', 'auth/token/revoke-self', {}, token=writer)
print('Rendered OpenBao policy and actual guest AppRole client: first identity recorded/read; unsafe writes, metadata changes, deletion and token administration denied over verified local TLS.')
PY
bao kv delete secret/kubernetes/test-cluster/identity > /tmp/fixture/delete-result
python3 -B - <<'PY'
from contextlib import closing
from kubernetes_recovery import BootstrapReader
from kubernetes_object_store import OperationError, private_json
with closing(BootstrapReader(private_json('/tmp/fixture/enrollment.json'), '/tmp/fixture/approle.json')) as reader:
    writer = reader.request('POST', 'auth/token/create/' + reader.enrollment['identity_token_role'], {
        'policies': [reader.enrollment['identity_writer_policy']], 'ttl': '60s', 'explicit_max_ttl': '60s',
        'renewable': False, 'no_default_policy': True})['auth']['client_token']
    try:
        reader.read('identity_path')
    except OperationError:
        pass
    else:
        raise AssertionError('Deleted identity history was interpreted as first creation')
    for cas in ['0', '1']:
        try:
            reader.request('POST', reader.enrollment['identity_path'], {'options': {'cas': cas}, 'data': {'changed': True}}, token=writer)
        except OperationError:
            continue
        raise AssertionError('Deleted identity history was overwritten')
    reader.request('POST', 'auth/token/revoke-self', {}, token=writer)
print('Deleted identity history blocks discovery and re-registration. Disposable fixture only; no production API or credential used.')
PY
