#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <grafana-version>\n' "$0" >&2
  exit 2
fi

readonly grafana_version="$1"
readonly grafana_key_fingerprint="B53AE77BADB630A683046005963FA27710458545"

key_file=$(mktemp)
gpg_home=$(mktemp -d)
chmod 0700 "$gpg_home"
trap 'rm -f "$key_file"; rm -rf "$gpg_home"; systemctl unmask grafana-server.service >/dev/null 2>&1 || true' EXIT

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install --yes gpg wget

wget --quiet --output-document "$key_file" https://apt.grafana.com/gpg-full.key
gpg --batch --homedir "$gpg_home" --import-options import-minimal --import "$key_file"
gpg --batch --homedir "$gpg_home" --list-keys "$grafana_key_fingerprint" >/dev/null

install -d -m 0755 /etc/apt/keyrings
gpg --batch --homedir "$gpg_home" --yes --output /etc/apt/keyrings/grafana.gpg --export "$grafana_key_fingerprint"
test -s /etc/apt/keyrings/grafana.gpg

cat >/etc/apt/sources.list.d/grafana.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main
EOF

cat >/etc/apt/preferences.d/grafana <<EOF
Package: grafana
Pin: version ${grafana_version}
Pin-Priority: 1001
EOF

systemctl mask grafana-server.service
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install --yes "grafana=${grafana_version}"
systemctl unmask grafana-server.service
