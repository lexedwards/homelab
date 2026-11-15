#!/usr/bin/env bash
set +x
set -Eeuo pipefail
umask 077
exec 3>&2 2>/dev/null
trap 'printf "Warehouse credential operation failed; no secret output is available.\n" >&3' ERR

[[ $EUID == 0 && ( $# == 1 || $# == 2 ) ]]
config=/etc/observability-warehouse/openbao.json
credential=/etc/observability-warehouse/approle.json
environment=/etc/observability-warehouse/object-storage.env
runtime=/run/observability-credentials

private_file() {
  [[ -f $1 && ! -L $1 && $(stat -c %u "$1") == 0 ]] || return 1
  (( (8#$(stat -c %a "$1") & 077) == 0 ))
}

[[ -f $config && ! -L $config && $(stat -c %u "$config") == 0 ]]
(( (8#$(stat -c %a "$config") & 022) == 0 ))
[[ ! -L /etc/observability-warehouse && $(stat -c %u /etc/observability-warehouse) == 0 ]]
(( (8#$(stat -c %a /etc/observability-warehouse) & 022) == 0 ))
jq -e '
  (.address | test("^https://[A-Za-z0-9.-]+(:[0-9]+)?$")) and
  (.auth_mount | test("^[a-z][a-z0-9-]*$")) and
  (.role_name == "observability-warehouse") and
  (.reader_policy == "observability-warehouse-read") and
  (.role_id | test("^[A-Za-z0-9-]+$")) and
  (.secret_path | test("^[a-z][a-z0-9-]*/data/[A-Za-z0-9_/-]+$")) and
  (.secret_path | split("/")[0] as $mount | ["sys","auth","identity","cubbyhole"] | index($mount) == null) and
  (.secret_path | split("/") | all(length > 0))
' "$config" >/dev/null
address=$(jq -r .address "$config")
role_id=$(jq -r .role_id "$config")
auth_mount=$(jq -r .auth_mount "$config")
secret_path=$(jq -r .secret_path "$config")
policy=$(jq -r .reader_policy "$config")
login_path="auth/$auth_mount/login"
creation_path="auth/$auth_mount/role/observability-warehouse/secret-id"

if [[ $1 != refresh ]]; then
  [[ ${2:-} =~ ^[a-f0-9]{64}$ ]]
  actual=$(jq -cSj . "$config" | sha256sum)
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
    curl --silent --fail --proto '=https' --connect-timeout 5 --max-time 20 \
      "$address/v1/sys/health" >/dev/null
    exit 10
  fi
  check_credential
  exit 0
fi
[[ $1 == enroll || $1 == activate || $1 == refresh ]]
systemd-tmpfiles --create /etc/tmpfiles.d/observability-credentials.conf
exec 9>"$runtime/lock"
flock -x -w 30 9
work=$(mktemp -d "$runtime/request.XXXXXX")
cleanup() {
  rm -f "$work"/*
  rmdir "$work"
}
trap cleanup EXIT

request() {
  local method=$1 path=$2 token_file=${3:-} data_file=${4:-}
  local -a options=(--silent --fail --proto '=https' --connect-timeout 5 --max-time 20 --max-filesize 1048576
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
  curl "${options[@]}" "$address/v1/$path"
}

authenticate() {
  local source=$1
  jq -n --slurpfile config "$config" --slurpfile credential "$source" \
    '{role_id:$config[0].role_id,secret_id:$credential[0].secret_id}' > "$work/login.json"
  request POST "$login_path" '' "$work/login.json"
  jq -e --arg policy "$policy" '
    .auth.policies == [$policy] and
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
    .data.creation_path == $path and
    .data.creation_ttl >= 60 and .data.creation_ttl <= 300
  ' "$work/response.json" >/dev/null
  request POST sys/wrapping/unwrap "$work/wrapped-token"
  jq -e '
    .data.secret_id_num_uses == 0 and .data.secret_id_ttl == 0 and
    (.data.secret_id | type == "string" and test("^[A-Za-z0-9-]+$")) and
    (.data.secret_id_accessor | type == "string" and length > 0)
  ' "$work/response.json" >/dev/null
  jq --arg role "$role_id" '{role_id:$role,secret_id:.data.secret_id,secret_id_accessor:.data.secret_id_accessor}' \
    "$work/response.json" > "$work/approle.json"
  authenticate "$work/approle.json"
  mv -T "$work/approle.json" "$credential"
fi

check_credential
if [[ $1 != refresh ]]; then
  flock -u 9
  systemctl enable --now observability-credentials.timer
  systemctl start observability-credentials.service
  exit 0
fi

if [[ ! -f $runtime/token ]] || ! request POST auth/token/renew-self "$runtime/token"; then
  authenticate "$credential"
fi
request GET "$secret_path" "$runtime/token"
jq -e '
  .data.data | [.AWS_ACCESS_KEY_ID,.AWS_SECRET_ACCESS_KEY] |
  all(type == "string" and length > 0 and (test("[\u0000-\u001f\u007f]") | not))
' "$work/response.json" >/dev/null
jq -r '.data.data | to_entries | map(select(.key == "AWS_ACCESS_KEY_ID" or .key == "AWS_SECRET_ACCESS_KEY")) |
  sort_by(.key)[] | .key + "=" + (.value | @json | gsub("\\$"; "$$"))' \
  "$work/response.json" > "$work/environment"
[[ ! -L $environment ]]
if [[ -e $environment ]]; then private_file "$environment"; fi
if ! cmp --silent "$work/environment" "$environment"; then
  mv -T "$work/environment" "$environment"
  systemctl restart observability-warehouse.service
else
  systemctl start observability-warehouse.service
fi
