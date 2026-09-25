#!/bin/bash
# Description: Orchestrates one LXC update, owns its single per-attempt log, and delegates update stages without implementing their domain logic.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 2 ]] || fail "usage: update.sh VMID_OR_NAME CONFIG_FILE"
target="$1"
config_file="$2"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine LXC script directory"
lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine lib directory"

config_get_script="$lib_dir/config/get.sh"
target_script="$script_dir/get-target.sh"
field_script="$script_dir/get-field.sh"
requirements_script="$lib_dir/workflows/check-requirements.sh"
log_init_script="$lib_dir/logging/init.sh"
log_capture_script="$lib_dir/logging/capture.sh"
log_write_script="$lib_dir/logging/write.sh"

for helper in \
  "$config_get_script" \
  "$target_script" \
  "$field_script" \
  "$requirements_script" \
  "$log_init_script" \
  "$log_capture_script" \
  "$log_write_script"; do
  [[ -r "$helper" ]] || fail "required helper is not readable: $helper"
done

# shellcheck source=/dev/null
source "$config_get_script" || fail "could not load config helpers"
config_get "$config_file" || fail "could not load Forge configuration: $config_file"

[[ "${CONFIG[UPDATE_LXC]}" == true ]] || fail "LXC updates are disabled by configuration"

target_record="$(bash "$target_script" "$target")" || fail "could not resolve LXC target '$target'"
vmid="$(bash "$field_script" "$target_record" vmid)" || fail "target record returned no vmid"
name="$(bash "$field_script" "$target_record" name)" || fail "target record returned no name"
state="$(bash "$field_script" "$target_record" state)" || fail "target record returned no state"
template="$(bash "$field_script" "$target_record" template)" || fail "target record returned no template flag"

[[ "$template" == false ]] || fail "LXC $vmid is a template and cannot be updated"

case "$state" in
  running)
    [[ "${CONFIG[UPDATE_RUNNING_LXC]}" == true ]] || fail "running LXCs are disabled by configuration"
    ;;
  stopped)
    [[ "${CONFIG[UPDATE_STOPPED_LXC]}" == true ]] || fail "stopped LXCs are disabled by configuration"
    ;;
  *)
    fail "unsupported LXC state '$state' for VMID $vmid"
    ;;
esac

log_file="$(
  bash "$log_init_script" \
    "${CONFIG[LOG_DIR]}" \
    "${CONFIG[LOG_KEEP]}" \
    lxc \
    "$vmid"
)" || fail "could not initialize update log for LXC $vmid"

bash "$log_write_script" "$log_file" INFO target_update_start \
  "vmid=$vmid" \
  "name=$name" \
  "state=$state" || fail "could not record update start for LXC $vmid"

started_at="$(date +%s)" || fail "could not create update start timestamp"

if [[ "${CONFIG[CHECK_LXC_REQUIREMENTS]}" == true ]]; then
  bash "$log_capture_script" "$log_file" requirements -- \
    bash "$requirements_script" "$vmid" "${CONFIG[CUSTOM_SCRIPTS_DIR]}"
  stage_result=$?

  if (( stage_result != 0 )); then
    finished_at="$(date +%s)" || finished_at="$started_at"
    duration_seconds=$((finished_at - started_at))

    bash "$log_write_script" "$log_file" ERROR target_update_end \
      "vmid=$vmid" \
      "status=failed" \
      "stage=requirements" \
      "exit_code=$stage_result" \
      "duration_seconds=$duration_seconds" || \
      printf 'ERROR: could not record failed update result in %s\n' "$log_file" >&2

    printf 'update=failed vmid=%s log=%s\n' "$vmid" "$log_file"
    exit "$stage_result"
  fi
else
  bash "$log_write_script" "$log_file" INFO stage_skipped \
    "stage=requirements" \
    "reason=disabled" || fail "could not record skipped requirements stage"
fi

# Mutating stages are intentionally not connected yet. The orchestration
# foundation stops here until backup, OS, application, custom-script, health
# and recovery stages are implemented and delegated from this script.
finished_at="$(date +%s)" || finished_at="$started_at"
duration_seconds=$((finished_at - started_at))

bash "$log_write_script" "$log_file" INFO orchestration_ready \
  "vmid=$vmid" \
  "duration_seconds=$duration_seconds" || fail "could not record orchestration readiness"

printf 'update=ready vmid=%s log=%s\n' "$vmid" "$log_file"
