#!/bin/bash
# Description: Runs non-recovery post-update maintenance for one successfully updated LXC.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: post-update.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

command -v pct >/dev/null 2>&1 || fail "pct is not available"
[[ -f "/etc/pve/lxc/${vmid}.conf" ]] || fail "LXC $vmid does not exist on this Proxmox host"

pct fstrim "$vmid"
result=$?

if (( result != 0 )); then
  printf 'ERROR: pct fstrim failed for LXC %s (exit code: %s)\n' "$vmid" "$result" >&2
  exit "$result"
fi

printf 'fstrim=success vmid=%s\n' "$vmid"
