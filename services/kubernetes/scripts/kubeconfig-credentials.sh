#!/usr/bin/env bash
set +x
set -Eeuo pipefail
umask 077
exec 3>&2 2>/dev/null
trap 'printf "Kubernetes application credential operation failed; no secret output is available.\n" >&3' ERR

[[ $EUID == 0 && ( $# == 1 || $# == 2 ) ]]
config=/etc/rancher/rke2/publication-openbao.json
publication=/etc/rancher/rke2/publication.json
credential=/etc/rancher/rke2/publication-approle.json
destination=/etc/rancher/rke2/publication-credentials.json
runtime=/run/kubernetes-publication-credentials

private_file() {
  [[ -f $1 && ! -L $1 && $(stat -c %u "$1") == 0 ]] || return 1
  (( (8#$(stat -c %a "$1") & 077) == 0 ))
}

private_file "$config"
private_file "$publication"
[[ ! -L /etc/rancher/rke2 && $(stat -c %u /etc/rancher/rke2) == 0 ]]
(( (8#$(stat -c %a /etc/rancher/rke2) & 022) == 0 ))
jq -e '
  (.address | test("^https://[A-Za-z0-9.-]+(:[0-9]+)?$")) and
  (.auth_mount | test("^[a-z][a-z0-9-]*$")) and
  (.role_name | test("^kubernetes-[a-z0-9-]+-kubeconfig$")) and
  (.reader_policy == .role_name + "-read") and
  (.role_id | test("^[A-Za-z0-9-]+$")) and
  (.secret_path | test("^[a-z][a-z0-9-]*/data/[A-Za-z0-9_/-]+$")) and
  (.secret_path | split("/")[0] as $mount | ["sys","auth","identity","cubbyhole"] | index($mount) == null) and
  (.secret_path | split("/") | all(length > 0))
' "$config" >/dev/null
address=$(jq -r .address "$config")
auth_mount=$(jq -r .auth_mount "$config")
role_name=$(jq -r .role_name "$config")
role_id=$(jq -r .role_id "$config")
policy=$(jq -r .reader_policy "$config")
secret_path=$(jq -r .secret_path "$config")
creation_path="auth/$auth_mount/role/$role_name/secret-id"

if [[ $1 != refresh ]]; then
  [[ ${2:-} =~ ^[a-f0-9]{64}$ ]]
  actual=$(jq -cnSj --slurpfile openbao "$config" --slurpfile publication "$publication" \
    '{openbao:$openbao[0],publication:$publication[0]}' | sha256sum)
  [[ ${actual%% *} == "$2" ]]
fi

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
    curl -q --silent --fail --proto '=https' --connect-timeout 5 --max-time 20 \
      "$address/v1/sys/health" >/dev/null
    exit 10
  fi
  check_credential
  exit 0
fi
[[ $1 == enroll || $1 == activate || $1 == refresh ]]
systemd-tmpfiles --create /etc/tmpfiles.d/kubernetes-publication.conf
exec 9>"$runtime/lock"
flock -x -w 30 9
work=$(mktemp -d /etc/rancher/rke2/.publication-request.XXXXXX)
cleanup() {
  rm -f "$work"/*
  rmdir "$work"
}
trap cleanup EXIT

request() {
  local method=$1 path=$2 token_file=${3:-} data_file=${4:-}
  local -a options=(--silent --fail --proto '=https' --connect-timeout 5 --max-time 20 --max-filesize 131072
    --request "$method" --output "$work/response.json" --header 'Content-Type: application/json')
  if [[ -n $token_file ]]; then
    private_file "$token_file" || return 1
    local token
    token=$(cat "$token_file")
    [[ $token =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    printf 'X-Vault-Token: %s\n' "$token" > "$work/header"
    options+=(--header "@$work/header")
  fi
  if [[ -n $data_file ]]; then options+=(--data-binary "@$data_file"); fi
  curl -q "${options[@]}" "$address/v1/$path"
}

authenticate() {
  jq -n --slurpfile config "$config" --slurpfile credential "$1" \
    '{role_id:$config[0].role_id,secret_id:$credential[0].secret_id}' > "$work/login.json"
  request POST "auth/$auth_mount/login" '' "$work/login.json"
  jq -e --arg policy "$policy" '
    .auth.policies == [$policy] and
    ((.auth.identity_policies // []) == []) and
    .auth.lease_duration > 0 and .auth.lease_duration <= 900 and
    (.auth.client_token | type == "string" and test("^[A-Za-z0-9._-]+$"))
  ' "$work/response.json" >/dev/null
  jq -r .auth.client_token "$work/response.json" > "$work/token"
  mv -T "$work/token" "$runtime/token"
}

if [[ $1 == enroll ]]; then
  [[ ! -e $credential && ! -L $credential ]]
  wrapped=$(head -c 65537)
  [[ $wrapped =~ ^[A-Za-z0-9._-]+$ && ${#wrapped} -le 65536 ]]
  printf '%s\n' "$wrapped" > "$work/wrapped-token"
  unset wrapped
  request POST sys/wrapping/lookup "$work/wrapped-token"
  jq -e --arg path "$creation_path" '
    .data.creation_path == $path and .data.creation_ttl >= 60 and .data.creation_ttl <= 300
  ' "$work/response.json" >/dev/null
  request POST sys/wrapping/unwrap "$work/wrapped-token"
  jq -e '
    .data.secret_id_num_uses == 0 and .data.secret_id_ttl == 0 and
    (.data.secret_id | type == "string" and test("^[A-Za-z0-9-]+$")) and
    (.data.secret_id_accessor | type == "string" and length > 0)
  ' "$work/response.json" >/dev/null
  jq --arg role "$role_id" '{role_id:$role,secret_id:.data.secret_id,secret_id_accessor:.data.secret_id_accessor}' \
    "$work/response.json" > "$work/approle.json"
  mv -T "$work/approle.json" "$credential"
  authenticate "$credential"
fi

check_credential
if [[ $1 != refresh ]]; then
  flock -u 9
  systemctl enable --now kubernetes-publication-credentials.timer
  systemctl start kubernetes-publication-credentials.service
  exit 0
fi
if [[ ! -f $runtime/token ]] || ! request POST auth/token/renew-self "$runtime/token"; then
  authenticate "$credential"
fi
request GET "$secret_path" "$runtime/token"
jq -e '
  .data.data | keys == ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"] and
  (.AWS_ACCESS_KEY_ID | type == "string" and test("^[A-Za-z0-9_-]{3,128}$")) and
  (.AWS_SECRET_ACCESS_KEY | type == "string" and test("^[!-~]{8,1024}$"))
' "$work/response.json" >/dev/null
jq -cS .data.data "$work/response.json" > "$work/credentials"
[[ ! -L $destination ]]
if [[ -e $destination ]]; then private_file "$destination"; fi
mv -T "$work/credentials" "$destination"
systemctl start kubernetes-kubeconfig-publication.service
