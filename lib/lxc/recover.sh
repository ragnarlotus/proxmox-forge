#!/bin/bash
# Description: Recovers one failed LXC update using its same-run persistent Proxmox snapshot, preserving older snapshots and returning the guest to running state.

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

[[ $# -eq 7 ]] || fail "usage: recover.sh VMID BACKUP_VOLUME SNAPSHOT_NAME LOG_FILE ROLLBACK_ENABLED FAILED_STAGE PRIMARY_EXIT_CODE"
vmid="$1"
backup_volume="$2"
snapshot_name="$3"
log_file="$4"
rollback_enabled="$5"
failed_stage="$6"
primary_result="$7"

[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"
[[ -f "$log_file" ]] || fail "log file does not exist: $log_file"
[[ -w "$log_file" ]] || fail "log file is not writable: $log_file"
[[ "$rollback_enabled" == true || "$rollback_enabled" == false ]] || fail "ROLLBACK_ENABLED must be true or false"
[[ "$failed_stage" =~ ^[a-z][a-z0-9_-]*$ ]] || fail "invalid failed stage '$failed_stage'"
[[ "$primary_result" =~ ^[0-9]+$ ]] || fail "PRIMARY_EXIT_CODE must be numeric"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine LXC script directory"
lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine lib directory"

state_script="$script_dir/get-state.sh"
log_capture_script="$lib_dir/logging/capture.sh"
log_write_script="$lib_dir/logging/write.sh"

for helper in \
  "$state_script" \
  "$log_capture_script" \
  "$log_write_script"; do
  [[ -r "$helper" ]] || fail "required helper is not readable: $helper"
done

command -v pct >/dev/null 2>&1 || fail "pct is not available"

if [[ "$rollback_enabled" != true ]]; then
  bash "$log_write_script" "$log_file" WARN recovery_skipped \
    "vmid=$vmid" \
    "failed_stage=$failed_stage" \
    "primary_exit_code=$primary_result" \
    "reason=disabled" || \
    printf 'ERROR: could not record skipped recovery in %s\n' "$log_file" >&2
  exit 0
fi

if [[ -z "$snapshot_name" ]]; then
  bash "$log_write_script" "$log_file" WARN recovery_skipped \
    "vmid=$vmid" \
    "failed_stage=$failed_stage" \
    "primary_exit_code=$primary_result" \
    "reason=no_recovery_snapshot" || \
    printf 'ERROR: could not record unavailable recovery in %s\n' "$log_file" >&2
  exit 0
fi

bash "$log_write_script" "$log_file" WARN recovery_start \
  "vmid=$vmid" \
  "failed_stage=$failed_stage" \
  "primary_exit_code=$primary_result" \
  "backup=$backup_volume" \
  "snapshot=$snapshot_name" || \
  printf 'ERROR: could not record recovery start in %s\n' "$log_file" >&2

current_state="$(bash "$state_script" "$vmid")"
recovery_result=$?
if (( recovery_result != 0 )); then
  bash "$log_write_script" "$log_file" ERROR recovery_end \
    "vmid=$vmid" \
    "status=failed" \
    "step=read_state" \
    "exit_code=$recovery_result" \
    "backup=$backup_volume" || true
  exit "$recovery_result"
fi

case "$current_state" in
  running)
    bash "$log_capture_script" "$log_file" recovery_stop -- pct stop "$vmid"
    recovery_result=$?
    if (( recovery_result != 0 )); then
      bash "$log_write_script" "$log_file" ERROR recovery_end \
        "vmid=$vmid" \
        "status=failed" \
        "step=stop" \
        "exit_code=$recovery_result" \
        "backup=$backup_volume" || true
      exit "$recovery_result"
    fi
    ;;
  stopped)
    bash "$log_write_script" "$log_file" INFO stage_skipped \
      "stage=recovery_stop" \
      "reason=already_stopped" || true
    ;;
  *)
    printf 'ERROR: unsupported LXC state during recovery: %s\n' "$current_state" >&2
    bash "$log_write_script" "$log_file" ERROR recovery_end \
      "vmid=$vmid" \
      "status=failed" \
      "step=stop" \
      "reason=unsupported_state" \
      "state=$current_state" \
      "backup=$backup_volume" || true
    exit 1
    ;;
esac

bash "$log_capture_script" "$log_file" recovery_rollback -- \
  pct rollback "$vmid" "$snapshot_name"
recovery_result=$?
if (( recovery_result != 0 )); then
  bash "$log_write_script" "$log_file" ERROR recovery_end \
    "vmid=$vmid" \
    "status=failed" \
    "step=rollback" \
    "exit_code=$recovery_result" \
    "backup=$backup_volume" || true
  exit "$recovery_result"
fi

# Recovery returns the guest to running state. The update orchestrator restores
# an explicitly targeted guest to stopped afterwards when that was its original state.
bash "$log_capture_script" "$log_file" recovery_start_guest -- pct start "$vmid"
recovery_result=$?
if (( recovery_result != 0 )); then
  bash "$log_write_script" "$log_file" ERROR recovery_end \
    "vmid=$vmid" \
    "status=failed" \
    "step=start" \
    "exit_code=$recovery_result" \
    "backup=$backup_volume" || true
  exit "$recovery_result"
fi

bash "$log_write_script" "$log_file" INFO recovery_end \
  "vmid=$vmid" \
  "status=success" \
  "backup=$backup_volume" \
  "snapshot=$snapshot_name" || \
  printf 'ERROR: could not record successful recovery in %s\n' "$log_file" >&2

exit 0
