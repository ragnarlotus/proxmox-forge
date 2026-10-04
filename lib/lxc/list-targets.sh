#!/bin/bash
# Description: Lists effective local running LXC update targets according to the configured LXC scope, always excluding templates and stopped containers.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run it through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 2 ]] || fail "usage: list-targets.sh UPDATE_LXC UPDATE_RUNNING_LXC"
update_lxc="$1"
update_running="$2"

for value in "$update_lxc" "$update_running"; do
  case "$value" in
    true|false) ;;
    *) fail "scope values must be true or false" ;;
  esac
done

[[ "$update_lxc" == true && "$update_running" == true ]] || exit 0

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
environment_script="$script_dir/get-environment.sh"
target_script="$script_dir/get-target.sh"
field_script="$script_dir/get-field.sh"

for helper in "$environment_script" "$target_script" "$field_script"; do
  [[ -r "$helper" ]] || fail "LXC helper is not readable: $helper"
done

bash "$environment_script" >/dev/null || fail "LXC environment check failed"

shopt -s nullglob
config_files=(/etc/pve/lxc/*.conf)
shopt -u nullglob

for config_file in "${config_files[@]}"; do
  vmid="${config_file##*/}"
  vmid="${vmid%.conf}"

  target_record="$(bash "$target_script" "$vmid")" || fail "could not read LXC target $vmid"
  name="$(bash "$field_script" "$target_record" name)" || fail "LXC target helper returned no name"
  state="$(bash "$field_script" "$target_record" state)" || fail "LXC target helper returned no state"
  template="$(bash "$field_script" "$target_record" template)" || fail "LXC target helper returned no template field"

  [[ "$template" == true ]] && continue
  [[ "$state" == stopped ]] && continue
  [[ "$state" == running ]] || fail "LXC $vmid returned unsupported state '$state'"

  printf 'type=lxc vmid=%s name=%s state=%s template=false\n' "$vmid" "$name" "$state"
done
