#!/bin/sh
set -eu
umask 022

version=$1
checksum=$2
test "$(. /etc/os-release; echo "$ID:$VERSION_ID")" = debian:13
test ! -e /opt/technitium/dns/DnsServerApp.dll

archive=$(mktemp /var/tmp/technitium.XXXXXX.tar.gz)
trap 'rm -f "$archive"' EXIT
trap 'exit 1' HUP INT TERM
curl --fail --silent --show-error --location --retry 3 \
  --connect-timeout 10 --max-time 300 \
  "https://download.technitium.com/dns/archive/$version/DnsServerPortable.tar.gz" \
  --output "$archive"
printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check --status
mkdir -p /opt/technitium/dns
tar --extract --gzip --file "$archive" --directory /opt/technitium/dns --no-same-owner
dotnet /opt/technitium/dns/DnsServerApp.dll --icu-test
