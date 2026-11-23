#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ ${1:-} != --inside ]]; then
  : "${BAO_BINARY:?Set BAO_BINARY to a reviewed local OpenBao server binary}"
  root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' EXIT
  for scope in default exact; do
    paths='[]'
    if [[ $scope == exact ]]; then paths='["kv/metadata/kubernetes/test-cluster/identity"]'; fi
    printf '%s\n' 'jsonencode(nonsensitive(local.administrator_policy))' | \
      tofu -chdir="$root" console -state="$work/console.tfstate" \
      -var='openbao_address=https://localhost:18200' -var="identity_metadata_paths=$paths" | \
      jq -erj fromjson > "$work/$scope.hcl"
  done
  cmp "$root/administrator.hcl" "$work/default.hcl"
  bwrap --unshare-all --uid 0 --gid 0 --clearenv --ro-bind / / --proc /proc --dev /dev --tmpfs /tmp \
    --bind "$work" /tmp/fixture --ro-bind "$root/scripts" /tmp/source --ro-bind "$BAO_BINARY" /tmp/bao \
    --setenv PATH /tmp:/usr/bin --setenv HOME /tmp/fixture \
    /usr/bin/bash /tmp/source/check-identity-metadata-access.sh --inside
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
bao secrets enable -path=kv -version=2 kv > /tmp/fixture/mount-result
for cluster in test-cluster other-cluster; do
  bao kv put "kv/kubernetes/$cluster/identity" uid=synthetic > /tmp/fixture/seed-result
done
bao policy write fixture-administrator /tmp/fixture/default.hcl > /tmp/fixture/policy-result
operator=$(bao token create -policy=fixture-administrator -no-default-policy -field=token)
deny() {
  if BAO_TOKEN="$operator" bao "$@" > /tmp/fixture/denied-result 2>&1; then
    printf '%s\n' 'Expected metadata/value denial was not enforced.' >&2
    exit 1
  fi
}
deny read kv/metadata/kubernetes/test-cluster/identity
deny write kv/metadata/kubernetes/test-cluster/identity cas_required=true
bao policy write fixture-administrator /tmp/fixture/exact.hcl > /tmp/fixture/policy-result
BAO_TOKEN="$operator" bao read -format=json kv/metadata/kubernetes/test-cluster/identity > /tmp/fixture/read-result.json
BAO_TOKEN="$operator" bao write kv/metadata/kubernetes/test-cluster/identity cas_required=true > /tmp/fixture/write-result
BAO_TOKEN="$operator" bao read -format=json kv/metadata/kubernetes/test-cluster/identity | \
  jq -e '.data.cas_required == true' >/dev/null
deny delete kv/metadata/kubernetes/test-cluster/identity
deny read kv/metadata/kubernetes/other-cluster/identity
deny write kv/metadata/kubernetes/other-cluster/identity cas_required=true
deny read kv/data/kubernetes/test-cluster/identity
deny write kv/data/kubernetes/test-cluster/identity uid=different
bao policy write fixture-administrator /tmp/fixture/default.hcl > /tmp/fixture/policy-result
deny read kv/metadata/kubernetes/test-cluster/identity
printf '%s\n' 'Exact metadata grant passed over local TLS: default/grant-removal denial, permitted read/update, denied deletion, other-record and secret-value access. No production credentials or API used.'
