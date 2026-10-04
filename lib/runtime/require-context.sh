#!/bin/bash
# Description: Verifies that an internal Forge component inherited the active global Forge runtime context and lock from the public Forge CLI.

set -u

fail_context() {
  printf 'ERROR: this Forge component is internal; run it through the forge CLI\n' >&2
  exit 1
}

[[ "${FORGE_CONTEXT:-}" == active ]] || fail_context
[[ -n "${FORGE_RUN_ID:-}" ]] || fail_context
[[ "${FORGE_LOCK_FILE:-}" == /* ]] || fail_context
[[ "${FORGE_LOCK_FD:-}" =~ ^[0-9]+$ ]] || fail_context

fd_path="/proc/$$/fd/${FORGE_LOCK_FD}"
[[ -e "$fd_path" ]] || fail_context

command -v readlink >/dev/null 2>&1 || fail_context
command -v flock >/dev/null 2>&1 || fail_context

fd_target="$(readlink "$fd_path" 2>/dev/null)" || fail_context
[[ "$fd_target" == "$FORGE_LOCK_FILE" ]] || fail_context

# The inherited descriptor refers to the same open file description that owns
# the lock. A non-blocking flock therefore succeeds only inside that run tree.
flock -n "$FORGE_LOCK_FD" || fail_context
