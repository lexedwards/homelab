#!/usr/bin/env bash
set +x
set -Eeuo pipefail
umask 077
exec 3>&2 2>/dev/null
trap 'printf "Kubernetes bootstrap introduction failed; preserved credentials and datastore require private inspection.\n" >&3' ERR

[[ $EUID == 0 && $# == 2 && $2 =~ ^[a-f0-9]{64}$ ]]
[[ $1 == check || $1 == enroll || $1 == activate ]]
config=/etc/rancher/rke2/bootstrap.json
credential=/etc/rancher/rke2/bootstrap-approle.json
runtime=/run/kubernetes-bootstrap
private_file() {
  [[ -f $1 && ! -L $1 && $(stat -c %u "$1") == 0 ]] || return 1
  (( (8#$(stat -c %a "$1") & 077) == 0 ))
}
private_file "$config"
[[ ! -L /etc/rancher/rke2 && $(stat -c %u /etc/rancher/rke2) == 0 ]]
(( (8#$(stat -c %a /etc/rancher/rke2) & 022) == 0 ))
actual=$(jq -cSj . "$config" | sha256sum)
[[ ${actual%% *} == "$2" ]]
/usr/bin/python3 -B /usr/local/libexec/homelab/rke2-bootstrap.py --config "$config" >/dev/null
jq -e '.mode != "existing" and (.access.role_name | test("^kubernetes-[a-z0-9-]+-bootstrap$"))' "$config" >/dev/null
address=$(jq -r .access.address "$config")
auth_mount=$(jq -r .access.auth_mount "$config")
role_name=$(jq -r .access.role_name "$config")
role_id=$(jq -r .access.role_id "$config")
creation_path="auth/$auth_mount/role/$role_name/secret-id"
check_credential() {
  private_file "$credential"
  jq -e --arg role "$role_id" '
    .role_id == $role and
    (.secret_id | type == "string" and test("^[A-Za-z0-9-]+$")) and
    (.secret_id_accessor | type == "string" and length > 0)
  ' "$credential" >/dev/null
}
if [[ $1 == check ]]; then
  if [[ ! -e $credential && ! -L $credential ]]; then
    curl -q --silent --fail --proto '=https' --connect-timeout 5 --max-time 20 "$address/v1/sys/health" >/dev/null
    exit 10
  fi
  check_credential
  exit 0
fi
systemd-tmpfiles --create /etc/tmpfiles.d/kubernetes-bootstrap.conf
exec 9>"$runtime/lock"
flock -x -w 30 9
work=$(mktemp -d /etc/rancher/rke2/.bootstrap-introduction.XXXXXX)
cleanup() {
  rm -f "$work"/*
  rmdir "$work"
}
trap cleanup EXIT
if [[ $1 == enroll ]]; then
  [[ ! -e $credential && ! -L $credential ]]
  wrapped=$(head -c 65537)
  [[ $wrapped =~ ^[A-Za-z0-9._-]+$ && ${#wrapped} -le 65536 ]]
  printf 'X-Vault-Token: %s\n' "$wrapped" > "$work/header"
  unset wrapped
  for operation in lookup unwrap; do
    curl -q --silent --fail --proto '=https' --connect-timeout 5 --max-time 20 --max-filesize 131072 \
      --request POST --header "@$work/header" --output "$work/response.json" "$address/v1/sys/wrapping/$operation"
    if [[ $operation == lookup ]]; then
      jq -e --arg path "$creation_path" '.data.creation_path == $path and .data.creation_ttl >= 60 and .data.creation_ttl <= 300' "$work/response.json" >/dev/null
    fi
  done
  jq -e '
    .data.secret_id_num_uses == 0 and .data.secret_id_ttl == 0 and
    (.data.secret_id | type == "string" and test("^[A-Za-z0-9-]+$")) and
    (.data.secret_id_accessor | type == "string" and length > 0)
  ' "$work/response.json" >/dev/null
  jq --arg role "$role_id" '{role_id:$role,secret_id:.data.secret_id,secret_id_accessor:.data.secret_id_accessor}' \
    "$work/response.json" > "$work/approle.json"
  mv -T "$work/approle.json" "$credential"
fi
check_credential
flock -u 9
systemctl enable --now kubernetes-bootstrap.timer
systemctl start kubernetes-bootstrap.service
