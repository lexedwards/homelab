#!/usr/bin/env bash
set +x
set -Eeuo pipefail
umask 077
exec 3>&2 2>/dev/null
trap 'printf "Warehouse SSH enrollment failed; inspect identity/access privately before retrying.\n" >&3' ERR

[[ ${BAO_ADDR:-} =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]]
[[ ${BAO_AUTH_MOUNT:-} =~ ^[a-z][a-z0-9-]*$ ]]
[[ ${WAREHOUSE_SSH_TARGET:-} =~ ^[a-z_][a-z0-9_-]*@[A-Za-z0-9.-]+$ ]]
[[ ${WAREHOUSE_CONFIG_SHA256:-} =~ ^[a-f0-9]{64}$ ]]
[[ -f ${WAREHOUSE_KNOWN_HOSTS:-} && ! -L $WAREHOUSE_KNOWN_HOSTS ]]
[[ $(stat -c %u "$WAREHOUSE_KNOWN_HOSTS") == "$EUID" ]]
(( (8#$(stat -c %a "$WAREHOUSE_KNOWN_HOSTS") & 022) == 0 ))
issuer_token=${BAO_TOKEN:-}
unset BAO_TOKEN

ssh_options=(-T -o BatchMode=yes -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$WAREHOUSE_KNOWN_HOSTS" -o GlobalKnownHostsFile=/dev/null
  -o ForwardAgent=no -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no
  -o ConnectTimeout=10 -o ConnectionAttempts=1 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
remote() {
  timeout 1000 ssh "${ssh_options[@]}" -- "$WAREHOUSE_SSH_TARGET" \
    "sudo -n /usr/local/sbin/warehouse-credentials $1 $WAREHOUSE_CONFIG_SHA256"
}
timeout 600 ssh "${ssh_options[@]}" -- "$WAREHOUSE_SSH_TARGET" \
  'sudo -n cloud-init status --wait' >/dev/null

status=0
remote check </dev/null || status=$?
if [[ $status == 0 ]]; then
  remote activate </dev/null
  exit 0
fi
[[ $status == 10 && $issuer_token =~ ^[A-Za-z0-9._-]+$ ]]
work=$(mktemp -d)
cleanup() {
  rm -f "$work"/*
  rmdir "$work"
}
trap cleanup EXIT
printf 'X-Vault-Token: %s\n' "$issuer_token" > "$work/header"
unset issuer_token
path="auth/$BAO_AUTH_MOUNT/role/observability-warehouse/secret-id"
curl --silent --fail --proto '=https' --connect-timeout 5 --max-time 20 --max-filesize 65536 \
  --request POST --header "@$work/header" --header 'X-Vault-Wrap-TTL: 120s' \
  --header 'Content-Type: application/json' --data '{}' \
  --output "$work/response.json" "$BAO_ADDR/v1/$path"
jq -e --arg path "$path" '.wrap_info.creation_path == $path and .wrap_info.ttl >= 60 and .wrap_info.ttl <= 300' \
  "$work/response.json" >/dev/null
jq -r .wrap_info.token "$work/response.json" | remote enroll
