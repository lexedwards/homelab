#!/usr/bin/env bash
set -euo pipefail
umask 077
source_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin"
printf '%s\n' '# Synthetic trust fixture; no real SSH connection is made.' > "$work/known_hosts"
cat > "$work/bin/ssh" <<'SSH'
#!/usr/bin/env bash
set -euo pipefail
case ${!#} in
  *'cloud-init status --wait') printf '%s\n' cloud-init >> /tmp/fixtures/actions ;;
  *'bootstrap-credentials install '*) cat > /tmp/fixtures/installed.json; printf '%s\n' install >> /tmp/fixtures/actions ;;
  *'bootstrap-credentials check '*) printf '%s\n' check >> /tmp/fixtures/actions; exit "$CHECK_STATUS" ;;
  *'bootstrap-credentials activate '*) printf '%s\n' activate >> /tmp/fixtures/actions; exit "$ACTIVATE_STATUS" ;;
  *'bootstrap-credentials enroll '*) read -r token; [[ $token == synthetic-wrapped-token ]]; printf '%s\n' enroll >> /tmp/fixtures/actions ;;
  *) exit 99 ;;
esac
SSH
cat > "$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' issue >> /tmp/fixtures/actions
while [[ $# -gt 0 ]]; do
  if [[ $1 == --output ]]; then
    printf '%s\n' '{"wrap_info":{"creation_path":"auth/approle/role/kubernetes-test-server-bootstrap/secret-id","ttl":120,"token":"synthetic-wrapped-token"}}' > "$2"
    exit 0
  fi
  shift
done
exit 99
CURL
chmod 0700 "$work/bin/ssh" "$work/bin/curl"
run_case() {
  : > "$work/actions"
  bwrap --unshare-all --clearenv --ro-bind / / --proc /proc --dev /dev --tmpfs /tmp \
    --bind "$work" /tmp/fixtures --ro-bind "$source_directory" /tmp/source --chdir /tmp/source \
    --setenv PATH /tmp/fixtures/bin:/usr/bin --setenv HOME /nonexistent --setenv TMPDIR /tmp/fixtures \
    --setenv BAO_ADDR https://bao.example.invalid --setenv BAO_AUTH_MOUNT approle \
    --setenv BAO_TOKEN "$3" --setenv PUBLICATION_ROLE kubernetes-test-server-bootstrap \
    --setenv CONTROL_PLANE_CREDENTIAL_HELPER bootstrap-credentials \
    --setenv CONTROL_PLANE_SSH_TARGET operator@guest.example.invalid \
    --setenv CONTROL_PLANE_KNOWN_HOSTS /tmp/fixtures/known_hosts \
    --setenv PUBLICATION_CONFIG_SHA256 "$(printf '%064d' 0)" \
    --setenv PUBLICATION_CONFIGURATION '{"synthetic":"non-secret enrollment"}' \
    --setenv CHECK_STATUS "$1" --setenv ACTIVATE_STATUS "$2" \
    /usr/bin/bash /tmp/source/enroll-control-plane.sh > "$work/stdout" 2> "$work/stderr"
}
run_case 10 0 synthetic-scoped-issuer || { cat "$work/stderr" "$work/actions"; exit 1; }
[[ $(cat "$work/actions") == $'cloud-init\ninstall\ncheck\nissue\nenroll' ]]
jq -e '.synthetic == "non-secret enrollment"' "$work/installed.json" >/dev/null
! grep -Eq 'synthetic-(scoped-issuer|wrapped-token)' "$work/stdout" "$work/stderr"
run_case 0 0 ''
[[ $(cat "$work/actions") == $'cloud-init\ninstall\ncheck\nactivate' ]]
if run_case 42 0 synthetic-scoped-issuer; then exit 1; fi
[[ $(cat "$work/actions") == $'cloud-init\ninstall\ncheck' ]]
if run_case 0 1 ''; then exit 1; fi
[[ $(cat "$work/actions") == $'cloud-init\ninstall\ncheck\nactivate' ]]
printf '%s\n' 'Enrollment transport fixtures passed: first introduction, credential reuse, check refusal and activation failure. No network or real credentials used.'
