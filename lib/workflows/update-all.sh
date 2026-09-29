#!/bin/bash
# Description: Coordinates the complete local Forge update sequence, validating and resolving LXC scope before mutation, updating the Proxmox host first, and only then running serial LXC updates.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: update-all.sh CONFIG_FILE"
config_file="$1"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine workflow directory"
lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine lib directory"

config_get_script="$lib_dir/config/get.sh"
host_update_script="$lib_dir/host/update.sh"
lxc_list_targets_script="$lib_dir/lxc/list-targets.sh"
lxc_update_all_script="$lib_dir/lxc/update-all.sh"

for helper in \
  "$config_get_script" \
  "$host_update_script" \
  "$lxc_list_targets_script" \
  "$lxc_update_all_script"; do
  [[ -r "$helper" ]] || fail "required helper is not readable: $helper"
done

# shellcheck source=/dev/null
source "$config_get_script" || fail "could not load config helpers"
config_get "$config_file" || fail "could not load Forge configuration: $config_file"

# Resolve the complete effective LXC scope before the first mutating operation.
targets_output="$(
  bash "$lxc_list_targets_script" \
    "${CONFIG[UPDATE_LXC]}" \
    "${CONFIG[UPDATE_RUNNING_LXC]}" \
    "${CONFIG[UPDATE_STOPPED_LXC]}"
)" || fail "could not resolve effective LXC target set"

lxc_targets=0
while IFS= read -r target_record; do
  [[ -n "$target_record" ]] || continue
  lxc_targets=$((lxc_targets + 1))
done <<< "$targets_output"

printf 'update_all=start update_host=%s update_lxc=%s lxc_targets=%s\n' \
  "${CONFIG[UPDATE_HOST]}" "${CONFIG[UPDATE_LXC]}" "$lxc_targets"

if [[ "${CONFIG[UPDATE_HOST]}" == true ]]; then
  printf 'update_all_stage=start stage=host\n'
  bash "$host_update_script" "$config_file"
  host_result=$?

  if (( host_result != 0 )); then
    printf 'update_all=failed stage=host exit_code=%s lxc_started=false\n' "$host_result"
    exit "$host_result"
  fi

  printf 'update_all_stage=success stage=host exit_code=0\n'
else
  printf 'update_all_stage=skipped stage=host reason=disabled\n'
fi

if [[ "${CONFIG[UPDATE_LXC]}" == true ]]; then
  printf 'update_all_stage=start stage=lxc targets=%s\n' "$lxc_targets"
  bash "$lxc_update_all_script" "$config_file"
  lxc_result=$?

  if (( lxc_result != 0 )); then
    printf 'update_all=failed stage=lxc exit_code=%s\n' "$lxc_result"
    exit "$lxc_result"
  fi

  printf 'update_all_stage=success stage=lxc targets=%s exit_code=0\n' "$lxc_targets"
else
  printf 'update_all_stage=skipped stage=lxc reason=disabled\n'
fi

printf 'update_all=success update_host=%s update_lxc=%s lxc_targets=%s\n' \
  "${CONFIG[UPDATE_HOST]}" "${CONFIG[UPDATE_LXC]}" "$lxc_targets"
