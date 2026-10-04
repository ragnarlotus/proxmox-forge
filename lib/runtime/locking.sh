#!/bin/bash
# Description: Provides the process-wide Forge mutation lock acquired only by the public Forge CLI before dispatching a mutating workflow.

set -u

forge_acquire_mutation_lock() {
  local command_name="$1"
  local lock_file="/run/lock/proxmox-forge.lock"
  local holder=""
  local run_id

  command -v flock >/dev/null 2>&1 || {
    printf 'ERROR: flock is required for Forge mutation locking\n' >&2
    return 1
  }

  [[ -d /run/lock && -w /run/lock ]] || {
    printf 'ERROR: Forge lock directory is not writable: /run/lock\n' >&2
    return 1
  }

  # Keep the descriptor open in the Forge process tree. The lock therefore
  # remains held for the complete delegated workflow, including child scripts.
  exec 200<>"$lock_file" || {
    printf 'ERROR: could not open Forge mutation lock: %s\n' "$lock_file" >&2
    return 1
  }

  if ! flock -n 200; then
    holder="$(cat "$lock_file" 2>/dev/null)"
    if [[ -n "$holder" ]]; then
      printf 'ERROR: another Forge mutating operation is already running (%s)\n' "$holder" >&2
    else
      printf 'ERROR: another Forge mutating operation is already running\n' >&2
    fi
    exec 200>&-
    return 1
  fi

  run_id="$(date '+%Y%m%dT%H%M%S')-$$" || {
    printf 'ERROR: could not create Forge run identifier\n' >&2
    exec 200>&-
    return 1
  }

  printf 'pid=%s run_id=%s command=%s\n' "$$" "$run_id" "$command_name" > "$lock_file" || {
    printf 'ERROR: could not record Forge mutation lock metadata\n' >&2
    exec 200>&-
    return 1
  }

  export FORGE_MUTATION_CONTEXT=active
  export FORGE_RUN_ID="$run_id"
  export FORGE_LOCK_FILE="$lock_file"
  export FORGE_LOCK_FD=200

  return 0
}
