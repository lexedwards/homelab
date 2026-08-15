#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <alloy-version>\n' "$0" >&2
  exit 2
fi

readonly alloy_version="$1"
readonly grafana_key_fingerprint="B53AE77BADB630A683046005963FA27710458545"

key_file=$(mktemp)
gpg_home=$(mktemp -d)
chmod 0700 "$gpg_home"
trap 'rm -f "$key_file"; rm -rf "$gpg_home"' EXIT

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install --yes gpg wget

wget --quiet --output-document "$key_file" https://apt.grafana.com/gpg.key
gpg --batch --homedir "$gpg_home" --import-options import-minimal --import "$key_file"
gpg --batch --homedir "$gpg_home" --list-keys "$grafana_key_fingerprint" >/dev/null

install -d -m 0755 /etc/apt/keyrings
gpg --batch --homedir "$gpg_home" --yes --output /etc/apt/keyrings/grafana.gpg --export "$grafana_key_fingerprint"
test -s /etc/apt/keyrings/grafana.gpg

cat >/etc/apt/sources.list.d/grafana.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main
EOF

cat >/etc/apt/preferences.d/alloy <<EOF
Package: alloy
Pin: version ${alloy_version}
Pin-Priority: 1001
EOF

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install --yes "alloy=${alloy_version}"
