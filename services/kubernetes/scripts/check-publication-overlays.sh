#!/usr/bin/env bash
set -euo pipefail
umask 077
source_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp/opencode}/publication-overlays-XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/config/config.yaml.d" "$work/state" "$work/bin"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" Enforcing' > "$work/bin/getenforce"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" 0' > "$work/bin/systemctl"
chmod 0700 "$work/bin/"*
printf '%s\n' '{"with-node-id":true,"tls-san":["api.example.invalid"]}' > "$work/config/config.yaml"
printf '%s\n' '{"token-file":"/etc/rancher/rke2/bootstrap-server-token"}' > "$work/config/config.yaml.d/90-bootstrap.yaml"
base=$(sha256sum "$work/config/config.yaml"); base=${base%% *}
overlay=$(sha256sum "$work/config/config.yaml.d/90-bootstrap.yaml"); overlay=${overlay%% *}
jq -n --arg base "$base" --arg overlay "$overlay" \
  '{role:"restore",configuration_sha256:$base,overlay_sha256:$overlay}' > "$work/state/decision.json"
jq -n --arg base "$base" \
  '{endpoint:"https://s3.example.invalid",region:"us-east-1",bucket:"test-cluster-configuration",cluster_name:"test-cluster",cluster_uid:"11111111-2222-4333-8444-555555555555",api_server:"https://api.example.invalid:6443",initializer:true,rke2_config_sha256:$base}' > "$work/config/publication.json"
printf '%s\n' '{"etcd-snapshot-schedule-cron":"0 */6 * * *","etcd-snapshot-retention":5,"etcd-s3-retention":56,"etcd-snapshot-compress":true,"etcd-s3":true,"etcd-s3-config-secret":"rke2-etcd-snapshot-s3-config"}' > "$work/native.json"
run_case() {
  bwrap --unshare-all --uid 0 --gid 0 --clearenv \
    --setenv PATH /tmp/bin:/usr/bin --setenv HOME /nonexistent --setenv LANG C.UTF-8 \
    --ro-bind / / --proc /proc --dev /dev --tmpfs /tmp --tmpfs /etc --tmpfs /var/lib \
    --ro-bind "$source_directory" /tmp/source --ro-bind "$work/bin" /tmp/bin \
    --bind "$work/config" /etc/rancher/rke2 --bind "$work/state" /var/lib/kubernetes-bootstrap \
    /usr/bin/python3 -B /tmp/source/publish-kubeconfig.py --execute --wait-seconds 1 \
    > "$work/stdout" 2> "$work/stderr"
}
for state in native legacy unsafe-native unknown-fragment join; do
  cp "$work/native.json" "$work/config/config.yaml.d/80-snapshots.yaml"
  rm -f "$work/config/config.yaml.d/unmanaged.yaml"
  case "$state" in
    legacy) rm "$work/config/config.yaml.d/80-snapshots.yaml" ;;
    unsafe-native) jq '. + {server:"https://other.example.invalid"}' "$work/native.json" > "$work/config/config.yaml.d/80-snapshots.yaml" ;;
    unknown-fragment) printf '%s\n' '{}' > "$work/config/config.yaml.d/unmanaged.yaml" ;;
    join) jq '.role="join"' "$work/state/decision.json" > "$work/decision.json"; mv "$work/decision.json" "$work/state/decision.json" ;;
  esac
  if [[ $state == join ]]; then
    run_case
    grep -q 'joining an existing cluster' "$work/stdout"
  else
    if run_case; then exit 1; fi
    case "$state" in
      native|legacy) grep -q 'RKE2 server startup deadline reached' "$work/stderr" || { cat "$work/stderr"; exit 1; } ;;
      unsafe-native) grep -q 'Unrecognized native snapshot configuration' "$work/stderr" ;;
      unknown-fragment) grep -q 'Managed runtime configuration differs' "$work/stderr" ;;
    esac
  fi
done
printf '%s\n' 'Publication overlay fixtures passed: native/legacy eligibility, unsafe/unknown fragments rejected, join skipped. No API, credential or native RKE2 operation.'
