#!/usr/bin/env bash
set -euo pipefail
umask 077
command -v bwrap >/dev/null
source_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
operation=(--execute)

new_case() {
  case_directory="$work/$1"
  mkdir -p "$case_directory/data" "$case_directory/state" "$case_directory/config"
  chmod 0700 "$case_directory/state"
  cat > "$case_directory/config/bootstrap.json" <<'JSON'
{"mode":"existing","configuration_sha256":"0000000000000000000000000000000000000000000000000000000000000000","node_name":"test-server","backup":null,"access":null,"recovery_point":null,"fencing_confirmed":false,"independent_custody_confirmed":false}
JSON
}

run_case() {
  bwrap --unshare-all --uid 0 --gid 0 --clearenv \
    --setenv PATH /usr/bin --setenv HOME /nonexistent --setenv LANG C.UTF-8 \
    --ro-bind / / --proc /proc --dev /dev --tmpfs /tmp --tmpfs /etc --tmpfs /var/lib \
    --ro-bind "$source_directory" /tmp/source --chdir /tmp/source \
    --bind "$case_directory/config" /etc/rancher/rke2 \
    --bind "$case_directory/data" /var/lib/rancher/rke2 \
    --bind "$case_directory/state" /var/lib/kubernetes-bootstrap \
    /usr/bin/python3 -B /tmp/source/rke2-bootstrap.py "${operation[@]}" "$@" \
    > "$case_directory/stdout" 2> "$case_directory/stderr"
}

new_case empty-default
if run_case; then
  echo 'Empty default lifecycle incorrectly allowed initialization.' >&2
  exit 1
fi
grep -q 'Empty datastore requires explicit create, join or restore intent' "$case_directory/stderr"

new_case initialized
mkdir -p "$case_directory/data/server/db/etcd/member/snap"
printf '%s\n' 'synthetic-database-must-not-change' > "$case_directory/data/server/db/etcd/member/snap/db"
before=$(sha256sum "$case_directory/data/server/db/etcd/member/snap/db")
run_case --config /absent-config --approle-file /absent-credential
grep -q 'Initialized datastore preserved' "$case_directory/stdout"
[[ $(sha256sum "$case_directory/data/server/db/etcd/member/snap/db") == "$before" ]]

new_case partial-datastore
mkdir -p "$case_directory/data/server/db/etcd"
if run_case; then
  echo 'Partial datastore was incorrectly accepted.' >&2
  exit 1
fi
grep -q 'Existing partial datastore requires inspection' "$case_directory/stderr"

new_case incomplete-reset
mkdir -p "$case_directory/data/server/db/etcd/member/snap"
printf '%s\n' 'preserve-failed-reset-evidence' > "$case_directory/data/server/db/etcd/member/snap/db"
printf '%s\n' '{"intent_sha256":"0000000000000000000000000000000000000000000000000000000000000000","snapshot_sha256":"1111111111111111111111111111111111111111111111111111111111111111"}' > "$case_directory/state/restore-started.json"
if run_case; then
  echo 'Incomplete reset allowed native startup.' >&2
  exit 1
fi
grep -q 'Incomplete or inconsistent restore attempt blocks startup' "$case_directory/stderr"

new_case completed-reset
mkdir -p "$case_directory/data/server/db/etcd/member/snap"
printf '%s\n' 'restored-datastore-must-not-reset-again' > "$case_directory/data/server/db/etcd/member/snap/db"
printf '%s\n' '{"intent_sha256":"0000000000000000000000000000000000000000000000000000000000000000","snapshot_sha256":"1111111111111111111111111111111111111111111111111111111111111111"}' > "$case_directory/state/restore-started.json"
cp "$case_directory/state/restore-started.json" "$case_directory/state/restore-complete.json"
printf '%s\n' '{"successful":true,"returncode":0}' > "$case_directory/state/restore-result.json"
run_case --config /absent-config --approle-file /absent-credential
grep -q 'Initialized datastore preserved' "$case_directory/stdout"

new_case missing-restored-data
printf '%s\n' '{"intent_sha256":"0000000000000000000000000000000000000000000000000000000000000000","snapshot_sha256":"1111111111111111111111111111111111111111111111111111111111111111"}' > "$case_directory/state/restore-started.json"
cp "$case_directory/state/restore-started.json" "$case_directory/state/restore-complete.json"
printf '%s\n' '{"successful":true,"returncode":0}' > "$case_directory/state/restore-result.json"
if run_case; then
  echo 'Missing previously restored data allowed initialization or reset replay.' >&2
  exit 1
fi
grep -q 'Previously restored datastore is missing' "$case_directory/stderr"

operation=()
for mode in create join restore; do
  new_case "plan-$mode"
  jq --arg mode "$mode" '
    .mode = $mode |
    .access = {address:"https://bao.example.invalid",auth_mount:"approle",role_name:"kubernetes-test-bootstrap",role_id:"test-role",reader_policy:"kubernetes-test-bootstrap-read",s3_secret_path:null,server_token_path:null} |
    if $mode != "join" then
      .backup = {endpoint:"https://s3.example.invalid",bucket:"test-backups",region:"us-east-1"} |
      .access.s3_secret_path = "secret/data/kubernetes/test/snapshot-reader"
    else . end |
    if $mode != "create" then .access.server_token_path = "secret/data/kubernetes/test/server-token/0123456789ab" else . end |
    if $mode == "restore" then
      .node_name = "test-replacement" | .fencing_confirmed = true | .independent_custody_confirmed = true |
      .recovery_point = {cluster_uid:"11111111-2222-4333-8444-555555555555",key:"rke2/11111111-2222-4333-8444-555555555555/homelab-scheduled-test-source-1730000000.zip",sha256:"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",size:4096,token_hash:"0123456789ab",source_node:"test-source",timestamp:1730000000,rke2_version:"v1.36.6+rke2r1",api_server:"https://api.example.invalid:6443"}
    else . end
  ' "$case_directory/config/bootstrap.json" > "$case_directory/config/selected.json"
  run_case --config /etc/rancher/rke2/selected.json --approle-file /absent-credential
  grep -q "Plan only: declared $mode lifecycle" "$case_directory/stdout"
  [[ ! -e $case_directory/state/lock ]]
done

printf '%s\n' 'Bootstrap filesystem guards passed in network-isolated user/mount namespaces; no RKE2, OpenBao or S3 operation executed.'
