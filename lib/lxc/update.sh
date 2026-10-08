#!/bin/bash
# Description: Orchestrates one protected LXC update, reusing an already-resolved target record when supplied, owns its single per-attempt log, delegates update stages, and attempts same-run backup recovery after post-mutation failure.

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

parse_record() {
  local record="$1"
  local field key

  RECORD_FIELDS=()
  for field in $record; do
    [[ "$field" == *=* ]] || continue
    key="${field%%=*}"
    RECORD_FIELDS["$key"]="${field#*=}"
  done
}

declare -A RECORD_FIELDS=()

[[ $# -ge 1 && $# -le 2 ]] || fail "usage: update.sh VMID_OR_NAME [TARGET_RECORD]"
target="$1"
target_record="${2:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine LXC script directory"
lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine lib directory"

config_get_script="$lib_dir/config/get.sh"
target_script="$script_dir/get-target.sh"
requirements_script="$lib_dir/workflows/check-requirements.sh"
backup_create_script="$lib_dir/backup/lxc/create.sh"
recovery_script="$script_dir/recover.sh"
os_update_script="$script_dir/update/os.sh"
application_update_script="$script_dir/update/application.sh"
custom_scripts_update_script="$script_dir/update/custom-scripts.sh"
fstrim_script="$script_dir/update/fstrim.sh"
health_script="$script_dir/health.sh"
log_init_script="$lib_dir/logging/init.sh"
log_capture_script="$lib_dir/logging/capture.sh"
log_write_script="$lib_dir/logging/write.sh"

for helper in \
  "$config_get_script" \
  "$target_script" \
  "$requirements_script" \
  "$backup_create_script" \
  "$recovery_script" \
  "$os_update_script" \
  "$application_update_script" \
  "$custom_scripts_update_script" \
  "$fstrim_script" \
  "$health_script" \
  "$log_init_script" \
  "$log_capture_script" \
  "$log_write_script"; do
  [[ -r "$helper" ]] || fail "required helper is not readable: $helper"
done

command -v mktemp >/dev/null 2>&1 || fail "mktemp is not available"
command -v tee >/dev/null 2>&1 || fail "tee is not available"

# shellcheck source=/dev/null
source "$config_get_script" || fail "could not load config helpers"
config_get || fail "could not load effective Forge configuration"

[[ "${CONFIG[UPDATE_LXC]}" == true ]] || fail "LXC updates are disabled by configuration"

if [[ -z "$target_record" ]]; then
  target_record="$(bash "$target_script" "$target")" || fail "could not resolve LXC target '$target'"
fi

parse_record "$target_record"
record_type="${RECORD_FIELDS[type]:-}"
vmid="${RECORD_FIELDS[vmid]:-}"
name="${RECORD_FIELDS[name]:-}"
state="${RECORD_FIELDS[state]:-}"
template="${RECORD_FIELDS[template]:-}"
[[ "$record_type" == lxc ]] || fail "target record returned invalid type '$record_type'"
[[ -n "$vmid" ]] || fail "target record returned no vmid"
[[ -n "$name" ]] || fail "target record returned no name"
[[ -n "$state" ]] || fail "target record returned no state"
[[ -n "$template" ]] || fail "target record returned no template flag"
[[ "$target" == "$vmid" || "$target" == "$name" ]] || \
  fail "target record does not match requested target '$target'"

[[ "$template" == false ]] || fail "LXC $vmid is a template and cannot be updated"

case "$state" in
  running)
    [[ "${CONFIG[UPDATE_RUNNING_LXC]}" == true ]] || fail "running LXCs are disabled by configuration"
    ;;
  stopped)
    fail "LXC $vmid is stopped; stopped LXC updates are not supported"
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
backup_volume=""
package_manager=""
application_updater=""
custom_script=false

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
    "vmid=$vmid" \
    "status=failed" \
    "stage=$failed_stage" \
    "exit_code=$primary_result" \
    "duration_seconds=$duration_seconds" || \
    printf 'ERROR: could not record failed update result in %s\n' "$log_file" >&2

  printf 'update=failed vmid=%s stage=%s exit_code=%s log=%s\n' \
    "$vmid" "$failed_stage" "$primary_result" "$log_file"
  exit "$primary_result"
}


if [[ "${CONFIG[CHECK_LXC_REQUIREMENTS]}" == true ]]; then
  requirements_output_file="$(mktemp)" || finish_failed requirements 1

  bash "$log_capture_script" "$log_file" requirements -- \
    bash -o pipefail -c 'bash "$1" "$2" "$3" | tee "$4"' \
      _ "$requirements_script" "$vmid" "$target_record" "$requirements_output_file"
  stage_result=$?

  if (( stage_result != 0 )); then
    rm -f "$requirements_output_file"
    finish_failed requirements "$stage_result"
  fi

  requirements_record="$(grep '^requirements=ok ' "$requirements_output_file" | tail -n 1)"
  rm -f "$requirements_output_file"

  parse_record "$requirements_record"
  package_manager="${RECORD_FIELDS[package_manager]:-}"
  application_updater="${RECORD_FIELDS[application_updater]:-}"
  custom_script="${RECORD_FIELDS[custom_script]:-}"
  [[ -n "$package_manager" ]] || finish_failed requirements 1
  [[ -n "$application_updater" ]] || finish_failed requirements 1
  [[ "$custom_script" == true || "$custom_script" == false ]] || finish_failed requirements 1
else
  record_skipped_stage requirements disabled

  if [[ "${CONFIG[RUN_CUSTOM_SCRIPTS]}" == true ]] \
    && [[ -d "${CONFIG[CUSTOM_SCRIPTS_DIR]}/$vmid" ]] \
    && find "${CONFIG[CUSTOM_SCRIPTS_DIR]}/$vmid" -maxdepth 1 -type f -name '*.sh' -print -quit 2>/dev/null | grep -q .; then
    custom_script=true
  fi
fi

application_update_planned=false
if [[ "${CONFIG[UPDATE_LXC_APPLICATION]}" == true ]]; then
  if [[ "${CONFIG[CHECK_LXC_REQUIREMENTS]}" != true || "$application_updater" != none ]]; then
    application_update_planned=true
  fi
fi

mutation_planned=false
if [[ "${CONFIG[UPDATE_LXC_OS]}" == true ]] \
  || [[ "$application_update_planned" == true ]] \
  || { [[ "${CONFIG[RUN_CUSTOM_SCRIPTS]}" == true ]] && [[ "$custom_script" == true ]]; }; then
  mutation_planned=true
fi

if [[ "$mutation_planned" == true ]]; then
  if [[ "${CONFIG[CREATE_BACKUP_BEFORE_LXC_UPDATE]}" == true ]]; then
    backup_output_file="$(mktemp)" || finish_failed backup 1

    bash "$log_capture_script" "$log_file" backup -- \
      bash -o pipefail -c 'bash "$1" "$2" | tee "$3"' \
        _ "$backup_create_script" "$vmid" "$backup_output_file"
    stage_result=$?

    if (( stage_result != 0 )); then
      rm -f "$backup_output_file"
      finish_failed backup "$stage_result"
    fi

    backup_record="$(grep '^backup=success ' "$backup_output_file" | tail -n 1)"
    rm -f "$backup_output_file"

    parse_record "$backup_record"
    backup_volume="${RECORD_FIELDS[volume]:-}"
    if [[ -z "$backup_volume" ]]; then
      bash "$log_write_script" "$log_file" ERROR backup_artifact_error \
        "vmid=$vmid" \
        "reason=missing_volume" || true
      finish_failed backup 1
    fi

    bash "$log_write_script" "$log_file" INFO recovery_artifact \
      "vmid=$vmid" \
      "backup=$backup_volume" || finish_failed backup 1
  else
    record_skipped_stage backup disabled
  fi
else
  record_skipped_stage backup no_mutating_stages
fi

if [[ "${CONFIG[UPDATE_LXC_OS]}" == true ]]; then
  bash "$log_capture_script" "$log_file" os_update -- \
    bash "$os_update_script" "$vmid" "$package_manager"
  stage_result=$?

  if (( stage_result != 0 )); then
    bash "$recovery_script" \
      "$vmid" "$backup_volume" "$log_file" "${CONFIG[ROLLBACK_ON_FAILURE]}" \
      os_update "$stage_result" || true
    finish_failed os_update "$stage_result"
  fi
else
  record_skipped_stage os_update disabled
fi

if [[ "${CONFIG[UPDATE_LXC_APPLICATION]}" == true ]]; then
  bash "$log_capture_script" "$log_file" application_update -- \
    bash "$application_update_script" "$vmid" "$application_updater"
  stage_result=$?

  if (( stage_result != 0 )); then
    bash "$recovery_script" \
      "$vmid" "$backup_volume" "$log_file" "${CONFIG[ROLLBACK_ON_FAILURE]}" \
      application_update "$stage_result" || true
    finish_failed application_update "$stage_result"
  fi
else
  record_skipped_stage application_update disabled
fi

if [[ "${CONFIG[RUN_CUSTOM_SCRIPTS]}" != true ]]; then
  record_skipped_stage custom_scripts disabled
elif [[ "$custom_script" != true ]]; then
  record_skipped_stage custom_scripts no_scripts
else
  bash "$log_capture_script" "$log_file" custom_scripts -- \
    bash "$custom_scripts_update_script" "$vmid" "${CONFIG[CUSTOM_SCRIPTS_DIR]}"
  stage_result=$?

  if (( stage_result != 0 )); then
    bash "$recovery_script" \
      "$vmid" "$backup_volume" "$log_file" "${CONFIG[ROLLBACK_ON_FAILURE]}" \
      custom_scripts "$stage_result" || true
    finish_failed custom_scripts "$stage_result"
  fi
fi

if [[ "$mutation_planned" == true && "${CONFIG[HEALTH_CHECK]}" == true ]]; then
  bash "$log_capture_script" "$log_file" health -- \
    bash "$health_script" "$vmid"
  stage_result=$?

  if (( stage_result != 0 )); then
    bash "$recovery_script" \
      "$vmid" "$backup_volume" "$log_file" "${CONFIG[ROLLBACK_ON_FAILURE]}" \
      health "$stage_result" || true
    finish_failed health "$stage_result"
  fi
elif [[ "${CONFIG[HEALTH_CHECK]}" != true ]]; then
  record_skipped_stage health disabled
else
  record_skipped_stage health no_mutating_stages
fi

if [[ "$mutation_planned" == true ]]; then
  bash "$log_capture_script" "$log_file" fstrim -- \
    bash "$fstrim_script" "$vmid"
  stage_result=$?

  if (( stage_result != 0 )); then
    bash "$log_write_script" "$log_file" WARN post_update_failed \
      "vmid=$vmid" \
      "stage=fstrim" \
      "exit_code=$stage_result" || \
      printf 'ERROR: could not record failed post-update fstrim in %s\n' "$log_file" >&2
    printf 'WARNING: post-update fstrim failed for LXC %s (exit code: %s)\n' \
      "$vmid" "$stage_result" >&2
  fi
else
  record_skipped_stage fstrim no_mutating_stages
fi

finished_at="$(date +%s)" || finished_at="$started_at"
duration_seconds=$((finished_at - started_at))

bash "$log_write_script" "$log_file" INFO target_update_end \
  "vmid=$vmid" \
  "status=success" \
  "duration_seconds=$duration_seconds" || fail "could not record successful update result"

printf 'update=success vmid=%s log=%s\n' "$vmid" "$log_file"
