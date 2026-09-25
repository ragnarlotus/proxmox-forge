#!/bin/bash
# Description: Orchestrates one local Proxmox VE host update, owns its host log, preserves the real failure result, and never attempts guest-style rollback.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: update.sh CONFIG_FILE"
config_file="$1"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine host script directory"
lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine lib directory"

config_get_script="$lib_dir/config/get.sh"
requirements_script="$script_dir/check-requirements.sh"
os_update_script="$script_dir/update/os.sh"
log_init_script="$lib_dir/logging/init.sh"
log_capture_script="$lib_dir/logging/capture.sh"
log_write_script="$lib_dir/logging/write.sh"

for helper in \
  "$config_get_script" \
  "$requirements_script" \
  "$os_update_script" \
  "$log_init_script" \
  "$log_capture_script" \
  "$log_write_script"; do
  [[ -r "$helper" ]] || fail "required helper is not readable: $helper"
done

command -v hostname >/dev/null 2>&1 || fail "hostname is not available"

# shellcheck source=/dev/null
source "$config_get_script" || fail "could not load config helpers"
config_get "$config_file" || fail "could not load Forge configuration: $config_file"

[[ "${CONFIG[UPDATE_HOST]}" == true ]] || fail "host updates are disabled by configuration"

hostname_fqdn="$(hostname -f 2>/dev/null)" || fail "could not determine host FQDN"
[[ -n "$hostname_fqdn" ]] || fail "host FQDN is empty"

log_file="$(
  bash "$log_init_script" \
    "${CONFIG[LOG_DIR]}" \
    "${CONFIG[LOG_KEEP]}" \
    host \
    "$hostname_fqdn"
)" || fail "could not initialize update log for host $hostname_fqdn"

bash "$log_write_script" "$log_file" INFO target_update_start \
  "type=host" \
  "hostname=$hostname_fqdn" || fail "could not record host update start"

started_at="$(date +%s)" || fail "could not create host update start timestamp"

finish_failed() {
  local failed_stage="$1"
  local primary_result="$2"
  local finished_at
  local duration_seconds

  finished_at="$(date +%s)" || finished_at="$started_at"
  duration_seconds=$((finished_at - started_at))

  bash "$log_write_script" "$log_file" ERROR target_update_end \
    "type=host" \
    "hostname=$hostname_fqdn" \
    "status=failed" \
    "stage=$failed_stage" \
    "exit_code=$primary_result" \
    "rollback=unsupported" \
    "duration_seconds=$duration_seconds" || \
    printf 'ERROR: could not record failed host update result in %s\n' "$log_file" >&2

  printf 'update=failed type=host hostname=%s stage=%s exit_code=%s rollback=unsupported log=%s\n' \
    "$hostname_fqdn" "$failed_stage" "$primary_result" "$log_file"
  exit "$primary_result"
}

bash "$log_capture_script" "$log_file" requirements -- \
  bash "$requirements_script"
stage_result=$?
if (( stage_result != 0 )); then
  finish_failed requirements "$stage_result"
fi

bash "$log_capture_script" "$log_file" os_update -- \
  bash "$os_update_script"
stage_result=$?
if (( stage_result != 0 )); then
  finish_failed os_update "$stage_result"
fi

if [[ "${CONFIG[HEALTH_CHECK]}" == true ]]; then
  bash "$log_capture_script" "$log_file" health -- \
    bash "$requirements_script"
  stage_result=$?
  if (( stage_result != 0 )); then
    finish_failed health "$stage_result"
  fi
else
  bash "$log_write_script" "$log_file" INFO stage_skipped \
    "stage=health" \
    "reason=disabled" || fail "could not record skipped host health stage"
fi

finished_at="$(date +%s)" || finished_at="$started_at"
duration_seconds=$((finished_at - started_at))

bash "$log_write_script" "$log_file" INFO target_update_end \
  "type=host" \
  "hostname=$hostname_fqdn" \
  "status=success" \
  "duration_seconds=$duration_seconds" || fail "could not record successful host update result"

printf 'update=success type=host hostname=%s log=%s\n' "$hostname_fqdn" "$log_file"
