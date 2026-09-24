#!/bin/bash

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: get-running.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

command -v pct >/dev/null 2>&1 || fail "pct is not available"
[[ -f "/etc/pve/lxc/${vmid}.conf" ]] || fail "LXC $vmid does not exist"

state="$(pct status "$vmid")" || fail "could not read state for LXC $vmid"
state="${state#status: }"

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
