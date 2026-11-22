#!/usr/bin/env bash
set +x
set -Eeuo pipefail
umask 077
exec 3>&2 2>/dev/null
trap 'printf "Kubernetes publication enrollment failed; inspect host identity/access privately.\n" >&3' ERR

[[ ${BAO_ADDR:-} =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]]
[[ ${BAO_AUTH_MOUNT:-} =~ ^[a-z][a-z0-9-]*$ ]]
helper=${CONTROL_PLANE_CREDENTIAL_HELPER:-kubeconfig-credentials}
[[ $helper == kubeconfig-credentials || $helper == bootstrap-credentials ]]
if [[ $helper == bootstrap-credentials ]]; then
  [[ ${PUBLICATION_ROLE:-} =~ ^kubernetes-[a-z0-9-]+-bootstrap$ ]]
else
  [[ ${PUBLICATION_ROLE:-} =~ ^kubernetes-[a-z0-9-]+-kubeconfig$ ]]
fi
[[ ${CONTROL_PLANE_SSH_TARGET:-} =~ ^[a-z_][a-z0-9_-]*@[A-Za-z0-9.-]+$ ]]
[[ ${PUBLICATION_CONFIG_SHA256:-} =~ ^[a-f0-9]{64}$ ]]
[[ -f ${CONTROL_PLANE_KNOWN_HOSTS:-} && ! -L $CONTROL_PLANE_KNOWN_HOSTS ]]
[[ $(stat -c %u "$CONTROL_PLANE_KNOWN_HOSTS") == "$EUID" ]]
(( (8#$(stat -c %a "$CONTROL_PLANE_KNOWN_HOSTS") & 022) == 0 ))
issuer_token=${BAO_TOKEN:-}
unset BAO_TOKEN

ssh_options=(-T -o BatchMode=yes -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$CONTROL_PLANE_KNOWN_HOSTS" -o GlobalKnownHostsFile=/dev/null
  -o ForwardAgent=no -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no
  -o ConnectTimeout=10 -o ConnectionAttempts=1 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
remote() {
  timeout 1000 ssh "${ssh_options[@]}" -- "$CONTROL_PLANE_SSH_TARGET" \
    "sudo -n /usr/local/sbin/$helper $1 $PUBLICATION_CONFIG_SHA256"
}
timeout 600 ssh "${ssh_options[@]}" -- "$CONTROL_PLANE_SSH_TARGET" 'sudo -n cloud-init status --wait' >/dev/null
if [[ -n ${PUBLICATION_CONFIGURATION:-} ]]; then
  printf '%s' "$PUBLICATION_CONFIGURATION" | remote install
  unset PUBLICATION_CONFIGURATION
fi
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
curl -q --silent --fail --proto '=https' --connect-timeout 5 --max-time 20 --max-filesize 65536 \
  --request POST --header "@$work/header" --header 'X-Vault-Wrap-TTL: 120s' \
  --header 'Content-Type: application/json' --data '{}' --output "$work/response.json" \
  "$BAO_ADDR/v1/auth/$BAO_AUTH_MOUNT/role/$PUBLICATION_ROLE/secret-id"
jq -e --arg path "auth/$BAO_AUTH_MOUNT/role/$PUBLICATION_ROLE/secret-id" '
  .wrap_info.creation_path == $path and .wrap_info.ttl >= 60 and .wrap_info.ttl <= 300
' "$work/response.json" >/dev/null
jq -r .wrap_info.token "$work/response.json" | remote enroll
