#!/bin/bash
# Description: Refuses direct execution of internal mutating Forge components unless they inherit the active Forge CLI mutation context and lock.

set -u

fail_context() {
  printf 'ERROR: this Forge component is internal; run mutating operations through the forge CLI\n' >&2
  exit 1
}

[[ "${FORGE_MUTATION_CONTEXT:-}" == active ]] || fail_context
[[ -n "${FORGE_RUN_ID:-}" ]] || fail_context
[[ "${FORGE_LOCK_FILE:-}" == /* ]] || fail_context
[[ "${FORGE_LOCK_FD:-}" =~ ^[0-9]+$ ]] || fail_context

fd_path="/proc/$$/fd/${FORGE_LOCK_FD}"
[[ -e "$fd_path" ]] || fail_context

command -v readlink >/dev/null 2>&1 || fail_context
command -v flock >/dev/null 2>&1 || fail_context

fd_target="$(readlink "$fd_path" 2>/dev/null)" || fail_context
[[ "$fd_target" == "$FORGE_LOCK_FILE" ]] || fail_context

# Re-locking the inherited descriptor is idempotent for the same open file
# description and proves that this process belongs to the active Forge lock.
flock -n "$FORGE_LOCK_FD" || fail_context
