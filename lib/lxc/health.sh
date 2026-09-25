#!/bin/bash
# Description: Performs the minimal generic post-update health check for one LXC by confirming it remains running and accepts a pct exec command; it does not perform logging or orchestration.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: health.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

command -v pct >/dev/null 2>&1 || fail "pct is not available"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine LXC script directory"
state_script="$script_dir/get-state.sh"
[[ -r "$state_script" ]] || fail "LXC state helper is not readable: $state_script"

state="$(bash "$state_script" "$vmid")" || fail "could not read state for LXC $vmid"
[[ "$state" == running ]] || fail "LXC $vmid is $state after update"

pct exec "$vmid" -- sh -c 'exit 0' </dev/null
health_result=$?

if (( health_result != 0 )); then
  printf 'ERROR: LXC %s is running but pct exec health check failed (exit code: %s)\n' \
    "$vmid" "$health_result" >&2
  exit "$health_result"
fi

printf 'health=ok vmid=%s state=running transport=pct_exec\n' "$vmid"
