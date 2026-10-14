#!/bin/bash
# Description: Recovers an LXC from its same-run vzdump backup after confirming safe restore, then checks guest health.

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

[[ $# -eq 6 ]] || fail "usage: recover.sh VMID BACKUP_VOLUME LOG_FILE ROLLBACK_ENABLED FAILED_STAGE PRIMARY_EXIT_CODE"
vmid="$1"
backup_volume="$2"
log_file="$3"
rollback_enabled="$4"
failed_stage="$5"
primary_result="$6"

[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"
[[ -f "$log_file" ]] || fail "log file does not exist: $log_file"
[[ -w "$log_file" ]] || fail "log file is not writable: $log_file"
[[ "$rollback_enabled" == true || "$rollback_enabled" == false ]] || fail "ROLLBACK_ENABLED must be true or false"
[[ "$failed_stage" =~ ^[a-z][a-z0-9_-]*$ ]] || fail "invalid failed stage '$failed_stage'"
[[ "$primary_result" =~ ^[0-9]+$ ]] || fail "PRIMARY_EXIT_CODE must be numeric"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine LXC script directory"
lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine lib directory"

state_script="$script_dir/get-state.sh"
backup_restore_script="$lib_dir/backup/lxc/restore.sh"
health_script="$script_dir/health.sh"
log_capture_script="$lib_dir/logging/capture.sh"
log_write_script="$lib_dir/logging/write.sh"

for helper in \
  "$state_script" \
  "$backup_restore_script" \
  "$health_script" \
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

if [[ -z "$backup_volume" ]]; then
  bash "$log_write_script" "$log_file" WARN recovery_skipped \
    "vmid=$vmid" \
    "failed_stage=$failed_stage" \
    "primary_exit_code=$primary_result" \
    "reason=no_recovery_artifact" || \
    printf 'ERROR: could not record unavailable recovery in %s\n' "$log_file" >&2
  exit 0
fi

bash "$log_write_script" "$log_file" WARN recovery_start \
  "vmid=$vmid" \
  "failed_stage=$failed_stage" \
  "primary_exit_code=$primary_result" \
  "backup=$backup_volume" \
  "recovery_mode=backup" || \
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

bash "$log_capture_script" "$log_file" recovery_restore -- \
  bash "$backup_restore_script" "$vmid" "$backup_volume"
recovery_result=$?
if (( recovery_result != 0 )); then
  bash "$log_write_script" "$log_file" ERROR recovery_end \
    "vmid=$vmid" \
    "status=failed" \
    "step=backup" \
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

# Wait for the restored guest to accept commands, then reuse the normal health check.
ready=false
deadline=$((SECONDS + 30))
while (( SECONDS < deadline )); do
  if timeout 2 pct exec "$vmid" -- true </dev/null >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done

if [[ "$ready" == true ]]; then
  bash "$log_capture_script" "$log_file" recovery_health -- bash "$health_script" "$vmid"
  recovery_result=$?
else
  printf 'ERROR: LXC %s did not become ready after recovery\n' "$vmid" >&2
  recovery_result=1
fi

if (( recovery_result != 0 )); then
  bash "$log_write_script" "$log_file" ERROR recovery_end \
    "vmid=$vmid" \
    "status=failed" \
    "step=health" \
    "exit_code=$recovery_result" \
    "backup=$backup_volume" || true
  exit "$recovery_result"
fi

bash "$log_write_script" "$log_file" INFO recovery_end \
  "vmid=$vmid" \
  "status=success" \
  "recovery_mode=backup" \
  "backup=$backup_volume" || \
  printf 'ERROR: could not record successful recovery in %s\n' "$log_file" >&2

exit 0
