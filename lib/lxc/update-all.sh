#!/bin/bash
# Description: Coordinates serial updates for all effective LXC targets, continuing after individual target failures and returning a failed aggregate result when any target fails.

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

[[ $# -eq 1 ]] || fail "usage: update-all.sh CONFIG_FILE"
config_file="$1"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine LXC script directory"
lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine lib directory"

config_get_script="$lib_dir/config/get.sh"
list_targets_script="$script_dir/list-targets.sh"
field_script="$script_dir/get-field.sh"
update_script="$script_dir/update.sh"

for helper in \
  "$config_get_script" \
  "$list_targets_script" \
  "$field_script" \
  "$update_script"; do
  [[ -r "$helper" ]] || fail "required helper is not readable: $helper"
done

# shellcheck source=/dev/null
source "$config_get_script" || fail "could not load config helpers"
config_get "$config_file" || fail "could not load Forge configuration: $config_file"

# Resolve the complete effective target set before the first mutating operation.
targets_output="$(
  bash "$list_targets_script" \
    "${CONFIG[UPDATE_LXC]}" \
    "${CONFIG[UPDATE_RUNNING_LXC]}" \
    "${CONFIG[UPDATE_STOPPED_LXC]}"
)" || fail "could not resolve effective LXC target set"

target_records=()
while IFS= read -r target_record; do
  [[ -n "$target_record" ]] || continue
  target_records+=("$target_record")
done <<< "$targets_output"

vmids=()
for target_record in "${target_records[@]}"; do
  vmid="$(bash "$field_script" "$target_record" vmid)" || \
    fail "target record returned no vmid: $target_record"
  [[ "$vmid" =~ ^[0-9]+$ ]] || fail "target record returned invalid vmid '$vmid'"
  vmids+=("$vmid")
done

total="${#vmids[@]}"
succeeded=0
failed=0

printf 'update_all=start targets=%s\n' "$total"

for vmid in "${vmids[@]}"; do
  printf 'update_all_target=start vmid=%s\n' "$vmid"

  bash "$update_script" "$vmid" "$config_file"
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
  printf 'update_all=failed total=%s succeeded=%s failed=%s\n' \
    "$total" "$succeeded" "$failed"
  exit 1
fi

printf 'update_all=success total=%s succeeded=%s failed=0\n' \
  "$total" "$succeeded"
