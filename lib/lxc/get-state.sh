#!/bin/bash

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: get-state.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
environment_script="$script_dir/get-environment.sh"
[[ -r "$environment_script" ]] || fail "LXC environment helper is not readable: $environment_script"
bash "$environment_script" >/dev/null || fail "LXC environment check failed"

[[ -f "/etc/pve/lxc/${vmid}.conf" ]] || fail "LXC $vmid does not exist"

state="$(pct status "$vmid")" || fail "could not read state for LXC $vmid"
state="${state#status: }"

case "$state" in
  running|stopped)
    printf '%s' "$state"
    ;;
  *)
    fail "LXC $vmid returned unsupported state '$state'"
    ;;
esac
