#!/bin/bash
# Description: Converts the current LXC state into a simple running=true/false record for callers that only need availability state.

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

[[ $# -eq 1 ]] || fail "usage: get-running.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
state_script="$script_dir/get-state.sh"
[[ -r "$state_script" ]] || fail "LXC state helper is not readable: $state_script"

state="$(bash "$state_script" "$vmid")" || fail "could not read state for LXC $vmid"

case "$state" in
  running)
    running=true
    ;;
  stopped)
    running=false
    ;;
  *)
    fail "LXC $vmid returned unsupported state '$state'"
    ;;
esac

printf 'vmid=%s state=%s running=%s\n' "$vmid" "$state" "$running"
