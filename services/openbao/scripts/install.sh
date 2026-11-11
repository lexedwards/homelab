#!/bin/sh
set -eu

version=$1
checksum=$2
test "$(dpkg --print-architecture)" = arm64
test "$(. /etc/os-release; echo "$ID:$VERSION_ID")" = debian:13

package=$(mktemp /var/tmp/openbao.XXXXXX.deb)
trap 'rm -f "$package"' EXIT HUP INT TERM
curl --fail --silent --show-error --location --retry 3 \
  --connect-timeout 10 --max-time 300 \
  "https://github.com/openbao/openbao/releases/download/v$version/openbao_${version}_linux_arm64.deb" \
  --output "$package"
printf '%s  %s\n' "$checksum" "$package" | sha256sum --check --status
DEBIAN_FRONTEND=noninteractive apt-get install --yes \
  -o Dpkg::Options::=--force-confold "$package"

chown root:openbao /etc/openbao /etc/openbao/openbao.hcl /etc/openbao/openbao.env /etc/openbao/acme-domain
chmod 0750 /etc/openbao
chmod 0640 /etc/openbao/openbao.hcl /etc/openbao/openbao.env
chmod 0640 /etc/openbao/acme-domain
chown openbao:openbao /opt/openbao/data
chmod 0700 /opt/openbao/data
install -d -o root -g openbao -m 0750 /etc/openbao/tls
install -d -o root -g root -m 0700 /etc/openbao-acme
systemctl daemon-reload
systemctl enable --now certbot.timer
systemctl enable --now openbao
