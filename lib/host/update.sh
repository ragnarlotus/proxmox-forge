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

[[ $# -eq 0 ]] || fail "usage: update.sh"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine host script directory"
lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine lib directory"

config_get_script="$lib_dir/config/get.sh"
requirements_script="$script_dir/check-requirements.sh"
backup_create_script="$lib_dir/backup/host/create.sh"
os_update_script="$script_dir/update/os.sh"
held_packages_script="$lib_dir/preflight/held-packages.sh"
reboot_script="$lib_dir/postflight/reboot-required.sh"
log_init_script="$lib_dir/logging/init.sh"
log_capture_script="$lib_dir/logging/capture.sh"
log_write_script="$lib_dir/logging/write.sh"
result_record_script="$lib_dir/results/record.sh"
apt_results_script="$lib_dir/results/apt.sh"

for helper in \
  "$config_get_script" \
  "$requirements_script" \
  "$backup_create_script" \
  "$os_update_script" \
  "$held_packages_script" \
  "$reboot_script" \
  "$log_init_script" \
  "$log_capture_script" \
  "$log_write_script" \
  "$result_record_script" \
  "$apt_results_script"; do
  [[ -r "$helper" ]] || fail "required helper is not readable: $helper"
done

for command_name in hostname mktemp tee; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is not available: $command_name"
done

# shellcheck source=/dev/null
source "$config_get_script" || fail "could not load config helpers"
config_get || fail "could not load effective Forge configuration"
# shellcheck source=/dev/null
source "$result_record_script" || fail "could not load result record helper"
# shellcheck source=/dev/null
source "$apt_results_script" || fail "could not load APT results helper"
trap forge_apt_cleanup EXIT

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
result_warning=""

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
  local explicit_error="${3:-}"
  local failure_error
  local finished_at
  local duration_seconds

  failure_error="$explicit_error"
  if [[ -z "$failure_error" ]]; then
    failure_error="$(forge_result_stage_error "$log_file" "$failed_stage")"
  fi
  forge_apt_finalize host
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
  printf 'Forge update summary: host %s FAILED at %s (exit code %s; no automatic rollback).\n' \
    "$hostname_fqdn" "$failed_stage" "$primary_result"
  forge_result_publish host HOST "$hostname_fqdn" true true ERROR update_failed "$primary_result" \
    "$FORGE_APT_COUNT" "-" "-" "-" "$failed_stage" "$failure_error" "-" "$result_warning"
  exit "$primary_result"
}

bash "$log_capture_script" "$log_file" requirements -- \
  bash "$requirements_script"
stage_result=$?
if (( stage_result != 0 )); then
  finish_failed requirements "$stage_result"
fi

forge_apt_begin host ||
  printf 'WARNING: cannot capture host APT baseline; upgrade count will be unavailable\n' >&2

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
    finish_failed backup 1 "backup artifact path missing or invalid"
  fi

  bash "$log_write_script" "$log_file" INFO backup_artifact \
    "type=host" \
    "backup=$backup_file" || finish_failed backup 1
else
  record_skipped_stage backup disabled
fi

FORGE_APT_ACTIVE=true
bash "$log_capture_script" "$log_file" os_update -- \
  bash "$os_update_script"
stage_result=$?

# Diagnose only held packages with pending candidate upgrades using refreshed
# APT lists, even if the OS update failed. A failed inspection is nonfatal.
bash "$log_capture_script" "$log_file" held_packages -- \
  bash "$held_packages_script" host
held_result=$?
if (( held_result != 0 )); then
  result_warning="held-package inspection failed (exit $held_result)"
  printf 'WARNING: could not inspect held APT packages on Proxmox host (exit code %s)\n' "$held_result" >&2
  bash "$log_write_script" "$log_file" WARN held_packages \
    "type=host" "status=unknown" "exit_code=$held_result" || \
    printf 'ERROR: could not log host held-package warning\n' >&2
fi

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

# A failed reboot-indicator check is informational, never a failed update.
reboot_required=unknown
reboot_record="$(bash "$reboot_script" host)"
reboot_check_result=$?
if (( reboot_check_result == 0 )) && [[ "$reboot_record" =~ ^reboot_required=(yes|no|unknown)[[:space:]]type=host[[:space:]] ]]; then
  reboot_required="${BASH_REMATCH[1]}"
  printf '%s\n' "$reboot_record"
  bash "$log_write_script" "$log_file" INFO reboot_status \
    "type=host" "reboot_required=$reboot_required" || fail "could not log host reboot status"
else
  if [[ -n "$result_warning" ]]; then result_warning+="; "; fi
  result_warning+="reboot requirement unknown (check exit $reboot_check_result)"
  printf 'WARNING: could not determine host reboot requirement (exit code %s)\n' "$reboot_check_result" >&2
  bash "$log_write_script" "$log_file" WARN reboot_status \
    "type=host" "reboot_required=unknown" "check_exit_code=$reboot_check_result" || \
    printf 'ERROR: could not log host reboot check warning\n' >&2
fi

forge_apt_finalize host
finished_at="$(date +%s)" || finished_at="$started_at"
duration_seconds=$((finished_at - started_at))

bash "$log_write_script" "$log_file" INFO target_update_end \
  "type=host" \
  "hostname=$hostname_fqdn" \
  "status=success" \
  "reboot_required=$reboot_required" \
  "backup=${backup_file:-none}" \
  "duration_seconds=$duration_seconds" || fail "could not record successful host update result"

printf 'update=success type=host hostname=%s backup=%s reboot_required=%s log=%s\n' \
  "$hostname_fqdn" "${backup_file:-none}" "$reboot_required" "$log_file"
printf 'Forge update summary: host %s SUCCESS.\n' "$hostname_fqdn"
if [[ "$reboot_required" == yes ]]; then
  printf 'NOTICE: Proxmox host reboot is indicated; Forge will not reboot automatically.\n'
elif [[ "$reboot_required" == unknown ]]; then
  printf 'WARNING: Proxmox host reboot requirement could not be determined.\n' >&2
fi
forge_result_publish host HOST "$hostname_fqdn" true true OK completed "" \
  "$FORGE_APT_COUNT" "-" "-" "-" "-" "" "-" "$result_warning"
