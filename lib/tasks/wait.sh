#!/bin/bash
# Description: Polls one Proxmox task UPID until it succeeds, fails, or exceeds the configured timeout.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run it through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || fail "usage: wait.sh UPID [TIMEOUT_SECONDS]"
upid="$1"
timeout="${2:-3600}"

[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || fail "timeout must be a positive integer"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
result_script="$script_dir/result.sh"
[[ -r "$result_script" ]] || fail "task result helper is not readable: $result_script"

started="$(date +%s)" || fail "could not read current time"

while :; do
  output="$(bash "$result_script" "$upid" 2>&1)"
  result=$?

  case "$result" in
    0)
      printf '%s\n' "$output"
      exit 0
      ;;
    1)
      printf '%s\n' "$output" >&2
      exit 1
      ;;
    2)
      now="$(date +%s)" || fail "could not read current time"
      if (( now - started >= timeout )); then
        fail "timed out after ${timeout}s waiting for Proxmox task $upid"
      fi
      sleep 2
      ;;
    *)
      printf '%s\n' "$output" >&2
      fail "unexpected task-result exit code $result"
      ;;
  esac
done
