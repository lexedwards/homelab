#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

base=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(git -C "$base" rev-parse --show-toplevel)
if [[ $(git -C "$repo" branch --show-current) != main || -f "$repo/.git" ]]; then
  printf '%s\n' 'Run only in the canonical checkout on main after adopting the new layout.' >&2
  exit 1
fi
if [[ -n ${TF_DATA_DIR:-} || -f "$base/main.tf" || -f "$base/authorization/main.tf" ]]; then
  printf '%s\n' 'Old configuration or a custom TF_DATA_DIR is present; stop and review migration.' >&2
  exit 1
fi

exec 9<"$base"
flock -n 9 || { printf '%s\n' 'Another local migration is running.' >&2; exit 1; }
shopt -s nullglob dotglob
sources=()
destinations=()

for pair in "$base:$base/init" "$base/authorization:$base/hardening"; do
  source_root=${pair%%:*}
  destination_root=${pair#*:}
  [[ -d "$destination_root" && ! -L "$destination_root" && -f "$destination_root/main.tf" ]] || exit 1
  [[ ! -L "$source_root" ]] || exit 1
  [[ -d "$source_root" ]] || continue

  for root in "$source_root" "$destination_root"; do
    if [[ -e "$root/.terraform.tfstate.lock.info" ]] ||
       { [[ -d "$root/terraform.tfstate.d" ]] &&
         [[ -n $(find "$root/terraform.tfstate.d" -name .terraform.tfstate.lock.info -print -quit) ]]; }; then
      printf '%s\n' 'An OpenTofu state lock exists; stop all operations and investigate it first.' >&2
      exit 1
    fi
  done

  for source in "$source_root/.terraform" "$source_root/terraform.tfstate" \
    "$source_root"/terraform.tfstate.* \
    "$source_root"/*.tfvars "$source_root"/*.tfvars.json \
    "$source_root/override.tf" "$source_root/override.tf.json" \
    "$source_root"/*_override.tf "$source_root"/*_override.tf.json; do
    [[ -e "$source" || -L "$source" ]] || continue
    destination="$destination_root/${source##*/}"
    if [[ -L "$source" || -e "$destination" || -L "$destination" ]]; then
      printf '%s\n' 'A symlink or destination collision exists; nothing was moved. Review privately.' >&2
      exit 1
    fi
    sources+=("$source")
    destinations+=("$destination")
  done
done

for index in "${!sources[@]}"; do
  mv --no-clobber -T -- "${sources[index]}" "${destinations[index]}"
  if [[ -e ${sources[index]} || -L ${sources[index]} ]]; then
    printf '%s\n' 'Move refused. Preserve both locations and investigate before continuing.' >&2
    exit 1
  fi
done

printf '%s\n' 'Local data migration complete. State contents and resource addresses were not changed.' \
  'Old saved plans were not moved. Do not apply them; generate fresh plans only with authorization.'
