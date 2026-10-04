#!/bin/bash
# Description: Orchestrates one local Proxmox VE host update, creates a configured recovery backup before mutation, owns host logging, preserves the real failure result, and never attempts guest-style rollback.

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

[[ $# -eq 1 ]] || fail "usage: update.sh CONFIG_FILE"
config_file="$1"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine host script directory"
lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine lib directory"

config_get_script="$lib_dir/config/get.sh"
requirements_script="$script_dir/check-requirements.sh"
backup_create_script="$lib_dir/backup/host/create.sh"
os_update_script="$script_dir/update/os.sh"
log_init_script="$lib_dir/logging/init.sh"
log_capture_script="$lib_dir/logging/capture.sh"
log_write_script="$lib_dir/logging/write.sh"

for helper in \
  "$config_get_script" \
  "$requirements_script" \
  "$backup_create_script" \
  "$os_update_script" \
  "$log_init_script" \
  "$log_capture_script" \
  "$log_write_script"; do
  [[ -r "$helper" ]] || fail "required helper is not readable: $helper"
done

for command_name in hostname mktemp tee; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is not available: $command_name"
done

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

error_log="${CONFIG[LOG_DIR]}/$hostname_fqdn/host/error.log"
[[ -f "$error_log" && -w "$error_log" ]] || fail "host error log is not available: $error_log"
export FORGE_ERROR_LOG="$error_log"

bash "$log_write_script" "$log_file" INFO target_update_start \
  "type=host" \
  "hostname=$hostname_fqdn" || fail "could not record host update start"

started_at="$(date +%s)" || fail "could not create host update start timestamp"
backup_file=""

record_skipped_stage() {
  local stage_name="$1"
  local reason="$2"

  bash "$log_write_script" "$log_file" INFO stage_skipped \
    "stage=$stage_name" \
    "reason=$reason" || fail "could not record skipped $stage_name stage"
}

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

if [[ "${CONFIG[CREATE_BACKUP_BEFORE_HOST_UPDATE]}" == true ]]; then
  backup_output_file="$(mktemp)" || finish_failed backup 1

  bash "$log_capture_script" "$log_file" backup -- \
    bash -o pipefail -c 'bash "$1" --extra-paths "$2" | tee "$3"' \
      _ "$backup_create_script" "${CONFIG[HOST_BACKUP_EXTRA_PATHS]}" "$backup_output_file"
  stage_result=$?

  if (( stage_result != 0 )); then
    rm -f "$backup_output_file"
    finish_failed backup "$stage_result"
  fi

  backup_record="$(grep '^backup=success type=host ' "$backup_output_file" | tail -n 1)"
  rm -f "$backup_output_file"
  backup_file="${backup_record##* path=}"

  if [[ -z "$backup_record" || "$backup_file" == "$backup_record" || ! -s "$backup_file" ]]; then
    bash "$log_write_script" "$log_file" ERROR backup_artifact_error \
      "type=host" \
      "reason=missing_or_invalid_path" || true
    finish_failed backup 1
  fi

  bash "$log_write_script" "$log_file" INFO backup_artifact \
    "type=host" \
    "backup=$backup_file" || finish_failed backup 1
else
  record_skipped_stage backup disabled
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
  record_skipped_stage health disabled
fi

finished_at="$(date +%s)" || finished_at="$started_at"
duration_seconds=$((finished_at - started_at))

bash "$log_write_script" "$log_file" INFO target_update_end \
  "type=host" \
  "hostname=$hostname_fqdn" \
  "status=success" \
  "backup=${backup_file:-none}" \
  "duration_seconds=$duration_seconds" || fail "could not record successful host update result"

printf 'update=success type=host hostname=%s backup=%s log=%s\n' \
  "$hostname_fqdn" "${backup_file:-none}" "$log_file"
