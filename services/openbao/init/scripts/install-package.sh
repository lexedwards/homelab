#!/bin/sh
set -eu

version=$1
checksum=$2
test "$(dpkg --print-architecture)" = arm64
test "$(. /etc/os-release; echo "$ID:$VERSION_ID")" = debian:13
test -d /opt/openbao/data
data_entry=$(find /opt/openbao/data -mindepth 1 -maxdepth 1 -print -quit)
if test -n "$data_entry"; then
    echo 'First-boot package installation requires an empty data volume; do not reprovision existing data.' >&2
    exit 1
fi

package=$(mktemp /var/tmp/openbao.XXXXXX.deb)
trap 'rm -f "$package"' EXIT HUP INT TERM
curl --fail --silent --show-error --location --retry 3 \
  --connect-timeout 10 --max-time 300 \
  "https://github.com/openbao/openbao/releases/download/v$version/openbao_${version}_linux_arm64.deb" \
  --output "$package"
printf '%s  %s\n' "$checksum" "$package" | sha256sum --check --status
DEBIAN_FRONTEND=noninteractive apt-get install --yes \
  -o Dpkg::Options::=--force-confold "$package"
