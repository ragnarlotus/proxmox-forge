#!/bin/bash
# Description: Coordinates the complete local Forge update sequence, freezing the effective LXC VMID scope before mutation, updating the Proxmox host first, then revalidating each selected LXC when its serial update begins.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run mutating operations through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 0 ]] || fail "usage: update-all.sh"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine workflow directory"
lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine lib directory"

config_get_script="$lib_dir/config/get.sh"
host_update_script="$lib_dir/host/update.sh"
lxc_list_targets_script="$lib_dir/lxc/list-targets.sh"
lxc_update_script="$lib_dir/lxc/update.sh"

for helper in \
  "$config_get_script" \
  "$host_update_script" \
  "$lxc_list_targets_script" \
  "$lxc_update_script"; do
  [[ -r "$helper" ]] || fail "required helper is not readable: $helper"
done

# shellcheck source=/dev/null
source "$config_get_script" || fail "could not load config helpers"
config_get || fail "could not load effective Forge configuration"

# Freeze only the effective LXC VMID scope before the first mutating operation. Each LXC is resolved again by update.sh when its turn begins so current state/template metadata are revalidated.
targets_output="$(
  bash "$lxc_list_targets_script" \
    "${CONFIG[UPDATE_LXC]}" \
    "${CONFIG[UPDATE_RUNNING_LXC]}"
)" || fail "could not resolve effective LXC target set"

vmids=()
while IFS= read -r target_record; do
  [[ -n "$target_record" ]] || continue

  vmid=""
  for field in $target_record; do
    if [[ "$field" == vmid=* ]]; then
      vmid="${field#*=}"
      break
    fi
  done

  [[ -n "$vmid" ]] || fail "target record returned no vmid: $target_record"
  [[ "$vmid" =~ ^[0-9]+$ ]] || fail "target record returned invalid vmid '$vmid'"

  vmids+=("$vmid")
done <<< "$targets_output"

lxc_targets="${#vmids[@]}"

printf 'update_all=start update_host=%s update_lxc=%s lxc_targets=%s\n' \
  "${CONFIG[UPDATE_HOST]}" "${CONFIG[UPDATE_LXC]}" "$lxc_targets"

if [[ "${CONFIG[UPDATE_HOST]}" == true ]]; then
  printf 'update_all_stage=start stage=host\n'
  bash "$host_update_script"
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
  succeeded=0
  failed=0

  printf 'update_all_stage=start stage=lxc targets=%s\n' "$lxc_targets"

  for vmid in "${vmids[@]}"; do
    printf 'update_all_target=start vmid=%s\n' "$vmid"

    bash "$lxc_update_script" "$vmid"
    target_result=$?

    if (( target_result == 0 )); then
      succeeded=$((succeeded + 1))
      printf 'update_all_target=success vmid=%s exit_code=0\n' "$vmid"
    else
      failed=$((failed + 1))
      printf 'update_all_target=failed vmid=%s exit_code=%s\n' "$vmid" "$target_result"
    fi
  done

  if (( failed != 0 )); then
    printf 'update_all_stage=failed stage=lxc total=%s succeeded=%s failed=%s exit_code=1\n' \
      "$lxc_targets" "$succeeded" "$failed"
    printf 'update_all=failed stage=lxc total=%s succeeded=%s failed=%s exit_code=1\n' \
      "$lxc_targets" "$succeeded" "$failed"
    exit 1
  fi

  printf 'update_all_stage=success stage=lxc total=%s succeeded=%s failed=0 exit_code=0\n' \
    "$lxc_targets" "$succeeded"
else
  printf 'update_all_stage=skipped stage=lxc reason=disabled\n'
fi

printf 'update_all=success update_host=%s update_lxc=%s lxc_targets=%s\n' \
  "${CONFIG[UPDATE_HOST]}" "${CONFIG[UPDATE_LXC]}" "$lxc_targets"
