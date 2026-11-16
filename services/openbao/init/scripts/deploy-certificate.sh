#!/bin/sh
set -eu
umask 077

test "${RENEWED_LINEAGE:-}" = /etc/letsencrypt/live/openbao || exit 0
exec 9>/run/lock/openbao-certificate.lock
flock -x 9
domain=$(cat /etc/openbao/acme-domain)
openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -noout -checkhost "$domain" >/dev/null
openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -noout -checkend 0 >/dev/null
openssl verify -CApath /etc/ssl/certs -untrusted "$RENEWED_LINEAGE/chain.pem" "$RENEWED_LINEAGE/cert.pem" >/dev/null
generation=$(mktemp -d /etc/openbao/tls/certificate.XXXXXX)
published=false
link="/etc/openbao/tls/.current.$$"
cleanup() {
    rm -f "$link"
    if test "$published" = false; then
        rm -f "$generation/fullchain.pem" "$generation/privkey.pem" \
            "$generation/certificate.pub" "$generation/certificate.der" "$generation/key.der"
        rmdir "$generation"
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -pubkey -noout -out "$generation/certificate.pub"
openssl pkey -pubin -in "$generation/certificate.pub" -outform DER -out "$generation/certificate.der"
openssl pkey -in "$RENEWED_LINEAGE/privkey.pem" -pubout -outform DER -out "$generation/key.der"
cmp -s "$generation/certificate.der" "$generation/key.der"
rm -f "$generation/certificate.pub" "$generation/certificate.der" "$generation/key.der"
install -o root -g openbao -m 0640 /dev/null "$generation/fullchain.pem"
cat "$RENEWED_LINEAGE/cert.pem" "$RENEWED_LINEAGE/chain.pem" > "$generation/fullchain.pem"
install -o root -g openbao -m 0640 "$RENEWED_LINEAGE/privkey.pem" "$generation/privkey.pem"
chown root:openbao "$generation"
chmod 0750 "$generation"
ln -s "$(basename "$generation")" "$link"
mv -Tf "$link" /etc/openbao/tls/current
published=true
if systemctl is-active --quiet openbao; then
    systemctl kill --kill-whom=main --signal=HUP openbao
fi
systemctl enable --now openbao-certificate-expiry.timer
