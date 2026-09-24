#!/bin/bash
# Description: Verifies that Forge is running on a Proxmox VE host with pct available and local LXC configuration accessible.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 0 ]] || fail "usage: get-environment.sh"

command -v pct >/dev/null 2>&1 || \
  fail "pct is not available; Forge LXC operations must run on a Proxmox VE host"

[[ -d /etc/pve/lxc ]] || \
  fail "/etc/pve/lxc is not available; Forge cannot access local LXC configuration"

printf 'environment=ok\n'
