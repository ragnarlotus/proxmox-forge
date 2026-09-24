#!/bin/bash

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: get-application-updater.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
state_script="$script_dir/get-state.sh"
[[ -r "$state_script" ]] || fail "LXC state helper is not readable: $state_script"

state="$(bash "$state_script" "$vmid")" || fail "could not read state for LXC $vmid"
[[ "$state" == running ]] || fail "LXC $vmid is $state; application-updater inspection requires a running container"

application_updater="$(pct exec "$vmid" -- sh -c '
  if [ -x /usr/bin/update ]; then
    printf "/usr/bin/update"
  else
    printf "none"
  fi
' </dev/null)" || fail "application-updater inspection failed for LXC $vmid"

printf 'vmid=%s application_updater=%s\n' "$vmid" "$application_updater"
