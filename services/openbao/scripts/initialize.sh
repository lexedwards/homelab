#!/usr/bin/env bash
set +x
set -Eeuo pipefail
umask 077
ulimit -c 0

if [[ ${1:-} == --help && $# == 1 ]]; then
  printf 'Usage: bash scripts/initialize.sh NEW_CUSTODY_DIRECTORY SHARES THRESHOLD\n'
  printf 'Initialize new Shamir/Raft storage over verified BAO_ADDR HTTPS; preserve protected output locally.\n'
  exit 0
fi

exec 3>&2 2>/dev/null
trap 'printf "Initialization stopped. Preserve any custody directory and inspect it privately; do not automatically retry.\n" >&3' ERR
trap 'printf "Initialization interrupted. Preserve the custody directory; server outcome may be uncertain.\n" >&3; exit 1' HUP INT TERM

[[ $# == 3 ]]
destination=$1
shares=$2
threshold=$3
[[ $shares =~ ^[1-9][0-9]{0,2}$ && $threshold =~ ^[1-9][0-9]{0,2}$ ]]
(( threshold <= shares && shares <= 255 ))
[[ ${BAO_ADDR:-} =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]]
[[ ${BAO_SKIP_VERIFY:-false} == false && -z ${BAO_AGENT_ADDR:-} && -z ${BAO_NAMESPACE:-} ]]
[[ -z ${BAO_TLS_SERVER_NAME:-} && -z ${BAO_WRAP_TTL:-} ]]
for command in bao jq timeout stat realpath sync; do command -v "$command" >/dev/null; done

[[ $destination == /* && ! -e $destination && ! -L $destination ]]
parent=$(dirname -- "$destination")
name=$(basename -- "$destination")
[[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $name != . && $name != .. ]]
[[ -d $parent && ! -L $parent && $(stat -c %u "$parent") == "$EUID" ]]
[[ $(stat -c %a "$parent") == 700 ]]
parent=$(realpath -e -- "$parent")
mkdir -m 0700 -- "$parent/$name"
cd -- "$parent/$name"
: > init.json
sync -f .

unset BAO_TOKEN
export BAO_MAX_RETRIES=0
status=0
timeout --kill-after=5s 30 bao status -format=json -tls-skip-verify=false -disable-redirects \
  > status-before.json 2> diagnostics.log || status=$?
[[ $status == 0 || $status == 2 ]]
jq -e '.initialized == false and .sealed == true and .type == "shamir" and .storage_type == "raft"' \
  status-before.json >/dev/null

timeout --kill-after=5s 60 bao operator init -format=json -tls-skip-verify=false -disable-redirects \
  -key-shares="$shares" -key-threshold="$threshold" > init.json 2>> diagnostics.log
sync -f init.json
jq -e --argjson shares "$shares" --argjson threshold "$threshold" '
  .unseal_shares == $shares and .unseal_threshold == $threshold and
  (.unseal_keys_b64 | length == $shares and all(type == "string" and length > 0)) and
  (.root_token | type == "string" and length > 0)
' init.json >/dev/null
status=0
timeout --kill-after=5s 30 bao status -format=json -tls-skip-verify=false -disable-redirects \
  > status-after.json 2>> diagnostics.log || status=$?
[[ $status == 2 ]]
jq -e --argjson shares "$shares" --argjson threshold "$threshold" '
  .initialized == true and .sealed == true and .type == "shamir" and
  .storage_type == "raft" and .n == $shares and .t == $threshold
' status-after.json >/dev/null
sync -f .
printf 'New storage initialized and still sealed. Recovery output is protected in the requested custody directory.\n'
printf 'Verify independent recovery custody before manual unseal, scoped administration and initial root-token revocation.\n'
