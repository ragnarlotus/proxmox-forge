#!/bin/bash
# Description: Resolves an exact LXC VMID or hostname and returns its canonical target record with name, state, and template flag.

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

[[ $# -eq 1 ]] || fail "usage: get-target.sh VMID_OR_NAME"
target="$1"
[[ -n "$target" ]] || fail "target must not be empty"

run_id="${FORGE_RUN_ID:-}"
[[ -n "$run_id" ]] || fail "Forge run identifier is unavailable"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
environment_script="$script_dir/get-environment.sh"
id_by_name_script="$script_dir/get-id-by-name.sh"
state_script="$script_dir/get-state.sh"
template_script="$script_dir/is-template.sh"

for helper in "$environment_script" "$id_by_name_script" "$state_script" "$template_script"; do
  [[ -r "$helper" ]] || fail "LXC helper is not readable: $helper"
done

if [[ "${FORGE_LXC_ENVIRONMENT_READY:-}" != "$run_id" ]]; then
  bash "$environment_script" >/dev/null || fail "LXC environment check failed"
  export FORGE_LXC_ENVIRONMENT_READY="$run_id"
fi

if [[ "$target" =~ ^[0-9]+$ ]]; then
  vmid="$target"
  config_file="/etc/pve/lxc/${vmid}.conf"
  [[ -f "$config_file" ]] || fail "no LXC exists with exact VMID '$target'"
  name="$(sed -n 's/^hostname:[[:space:]]*//p' "$config_file" | head -n 1)"
  [[ -n "$name" ]] || fail "LXC $vmid has no hostname in $config_file"
else
  vmid="$(bash "$id_by_name_script" "$target")" || fail "could not resolve LXC name '$target'"
  name="$target"
fi

state="$(bash "$state_script" "$vmid")" || fail "could not read state for LXC $vmid"
template="$(bash "$template_script" "$vmid")" || fail "could not determine whether LXC $vmid is a template"

printf 'type=lxc vmid=%s name=%s state=%s template=%s\n' \
  "$vmid" "$name" "$state" "$template"
