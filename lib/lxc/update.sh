#!/bin/bash
# Description: Orchestrates one protected LXC update, temporarily starts an explicitly selected stopped guest and restores its original state, delegates update stages, and attempts same-run backup recovery after post-mutation failure.

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

[[ $# -ge 1 && $# -le 2 ]] || fail "usage: update.sh VMID_OR_NAME [explicit|scope]"
target="$1"
selection_mode="${2:-explicit}"

case "$selection_mode" in
  explicit|scope) ;;
  *) fail "unsupported LXC selection mode '$selection_mode'" ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine LXC script directory"
lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine lib directory"

config_get_script="$lib_dir/config/get.sh"
target_script="$script_dir/get-target.sh"
state_script="$script_dir/get-state.sh"
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
  "$state_script" \
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

target_record="$(bash "$target_script" "$target")" || fail "could not resolve LXC target '$target'"
parse_record "$target_record"
vmid="${RECORD_FIELDS[vmid]:-}"
name="${RECORD_FIELDS[name]:-}"
state="${RECORD_FIELDS[state]:-}"
template="${RECORD_FIELDS[template]:-}"
[[ -n "$vmid" ]] || fail "target record returned no vmid"
[[ -n "$name" ]] || fail "target record returned no name"
[[ -n "$state" ]] || fail "target record returned no state"
[[ -n "$template" ]] || fail "target record returned no template flag"

[[ "$template" == false ]] || fail "LXC $vmid is a template and cannot be updated"

case "$state" in
  running)
    ;;
  stopped)
    [[ "$selection_mode" == explicit ]] || fail "LXC $vmid is stopped; automatic updates require running containers"
    ;;
  *)
    fail "unsupported LXC state '$state' for VMID $vmid"
    ;;
esac

initial_state="$state"

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
  "state=$initial_state" \
  "selection_mode=$selection_mode" || fail "could not record update start for LXC $vmid"

started_at="$(date +%s)" || fail "could not create update start timestamp"
backup_volume=""
package_manager=""
application_updater=""
custom_scripts_planned=false

record_skipped_stage() {
  local stage_name="$1"
  local reason="$2"

  bash "$log_write_script" "$log_file" INFO stage_skipped \
    "stage=$stage_name" \
    "reason=$reason" || fail "could not record skipped $stage_name stage"
}

wait_for_guest_exec() {
  local timeout_seconds=30
  local probe_timeout_seconds=2
  local started_seconds="$SECONDS"
  local elapsed_seconds

  bash "$log_write_script" "$log_file" INFO lifecycle_readiness_wait \
    "vmid=$vmid" \
    "initial_state=$initial_state" \
    "timeout_seconds=$timeout_seconds" || return 1

  while (( SECONDS - started_seconds < timeout_seconds )); do
    if timeout "$probe_timeout_seconds" pct exec "$vmid" -- sh -c ':' </dev/null >/dev/null 2>&1; then
      elapsed_seconds=$((SECONDS - started_seconds))
      bash "$log_write_script" "$log_file" INFO lifecycle_ready \
        "vmid=$vmid" \
        "transport=pct_exec" \
        "wait_seconds=$elapsed_seconds" || return 1
      return 0
    fi

    sleep 1
  done

  elapsed_seconds=$((SECONDS - started_seconds))
  bash "$log_write_script" "$log_file" ERROR lifecycle_readiness_timeout \
    "vmid=$vmid" \
    "transport=pct_exec" \
    "timeout_seconds=$timeout_seconds" \
    "wait_seconds=$elapsed_seconds" || true
  return 1
}

restore_initial_state() {
  local current_state
  local restore_result

  [[ "$initial_state" == stopped ]] || return 0

  current_state="$(bash "$state_script" "$vmid")"
  restore_result=$?
  if (( restore_result != 0 )); then
    bash "$log_write_script" "$log_file" ERROR lifecycle_restore_failed \
      "vmid=$vmid" \
      "target_state=stopped" \
      "step=read_state" \
      "exit_code=$restore_result" || true
    return "$restore_result"
  fi

  case "$current_state" in
    stopped)
      bash "$log_write_script" "$log_file" INFO stage_skipped \
        "stage=lifecycle_stop" \
        "reason=already_stopped" || true
      return 0
      ;;
    running)
      bash "$log_capture_script" "$log_file" lifecycle_stop -- pct shutdown "$vmid"
      restore_result=$?
      if (( restore_result != 0 )); then
        bash "$log_write_script" "$log_file" ERROR lifecycle_restore_failed \
          "vmid=$vmid" \
          "target_state=stopped" \
          "step=shutdown" \
          "exit_code=$restore_result" || true
        return "$restore_result"
      fi
      ;;
    *)
      bash "$log_write_script" "$log_file" ERROR lifecycle_restore_failed \
        "vmid=$vmid" \
        "target_state=stopped" \
        "step=read_state" \
        "reason=unsupported_state" \
        "state=$current_state" || true
      return 1
      ;;
  esac

  bash "$log_write_script" "$log_file" INFO lifecycle_restored \
    "vmid=$vmid" \
    "state=stopped" || return 1
}

finish_failed() {
  local failed_stage="$1"
  local primary_result="$2"
  local finished_at
  local duration_seconds
  local state_restore_result=0

  if [[ "$failed_stage" != lifecycle_restore ]]; then
    restore_initial_state || state_restore_result=$?
  fi

  finished_at="$(date +%s)" || finished_at="$started_at"
  duration_seconds=$((finished_at - started_at))

  bash "$log_write_script" "$log_file" ERROR target_update_end \
    "vmid=$vmid" \
    "status=failed" \
    "stage=$failed_stage" \
    "exit_code=$primary_result" \
    "state_restore_exit_code=$state_restore_result" \
    "duration_seconds=$duration_seconds" || \
    printf 'ERROR: could not record failed update result in %s\n' "$log_file" >&2

  if (( state_restore_result != 0 )); then
    printf 'WARNING: failed to restore original stopped state for LXC %s (exit code: %s)\n' \
      "$vmid" "$state_restore_result" >&2
  fi

  printf 'update=failed vmid=%s stage=%s exit_code=%s log=%s\n' \
    "$vmid" "$failed_stage" "$primary_result" "$log_file"
  exit "$primary_result"
}

if [[ "$initial_state" == stopped ]]; then
  command -v timeout >/dev/null 2>&1 || finish_failed lifecycle_readiness 1
  command -v sleep >/dev/null 2>&1 || finish_failed lifecycle_readiness 1

  bash "$log_capture_script" "$log_file" lifecycle_start -- pct start "$vmid"
  stage_result=$?
  if (( stage_result != 0 )); then
    finish_failed lifecycle_start "$stage_result"
  fi

  state="$(bash "$state_script" "$vmid")"
  stage_result=$?
  if (( stage_result != 0 )); then
    finish_failed lifecycle_start "$stage_result"
  fi
  [[ "$state" == running ]] || finish_failed lifecycle_start 1

  wait_for_guest_exec || finish_failed lifecycle_readiness 1

  target_record="type=lxc vmid=$vmid name=$name state=running template=false"
fi

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
[[ -n "$package_manager" ]] || finish_failed requirements 1
[[ -n "$application_updater" ]] || finish_failed requirements 1

# Discover local scripts independently of LXC requirements, before backup planning.
if [[ "${CONFIG[RUN_CUSTOM_SCRIPTS]}" == true ]] \
  && [[ -d "${CONFIG[CUSTOM_SCRIPTS_DIR]}/$vmid" ]] \
  && find "${CONFIG[CUSTOM_SCRIPTS_DIR]}/$vmid" -maxdepth 1 -type f -name '*.sh' -print -quit 2>/dev/null | grep -q .; then
  custom_scripts_planned=true
fi

application_update_planned=false
if [[ "${CONFIG[UPDATE_LXC_APPLICATION]}" == true && "$application_updater" != none ]]; then
  application_update_planned=true
fi

mutation_planned=false
if [[ "${CONFIG[UPDATE_LXC_OS]}" == true ]] \
  || [[ "$application_update_planned" == true ]] \
  || [[ "$custom_scripts_planned" == true ]]; then
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
elif [[ "$custom_scripts_planned" != true ]]; then
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

restore_initial_state
stage_result=$?
if (( stage_result != 0 )); then
  finish_failed lifecycle_restore "$stage_result"
fi

finished_at="$(date +%s)" || finished_at="$started_at"
duration_seconds=$((finished_at - started_at))

bash "$log_write_script" "$log_file" INFO target_update_end \
  "vmid=$vmid" \
  "status=success" \
  "initial_state=$initial_state" \
  "final_state=$initial_state" \
  "duration_seconds=$duration_seconds" || fail "could not record successful update result"

printf 'update=success vmid=%s initial_state=%s final_state=%s log=%s\n' \
  "$vmid" "$initial_state" "$initial_state" "$log_file"
