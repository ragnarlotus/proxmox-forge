#!/bin/bash
# Description: Returns the current Proxmox runtime state of one local LXC after validating the environment and VMID.

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

[[ $# -eq 1 ]] || fail "usage: get-state.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

run_id="${FORGE_RUN_ID:-}"
[[ -n "$run_id" ]] || fail "Forge run identifier is unavailable"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
environment_script="$script_dir/get-environment.sh"
[[ -r "$environment_script" ]] || fail "LXC environment helper is not readable: $environment_script"

if [[ "${FORGE_LXC_ENVIRONMENT_READY:-}" != "$run_id" ]]; then
  bash "$environment_script" >/dev/null || fail "LXC environment check failed"
  export FORGE_LXC_ENVIRONMENT_READY="$run_id"
fi

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
