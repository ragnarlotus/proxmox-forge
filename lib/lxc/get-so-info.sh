#!/bin/bash

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: get-so-info.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

command -v pct >/dev/null 2>&1 || fail "pct is not available"
[[ -f "/etc/pve/lxc/${vmid}.conf" ]] || fail "LXC $vmid does not exist"

state="$(pct status "$vmid")" || fail "could not read state for LXC $vmid"
state="${state#status: }"
[[ "$state" == running ]] || fail "LXC $vmid is $state; OS inspection requires a running container"

result="$(pct exec "$vmid" -- sh -c '
  set -u

  os_id=unknown
  os_version=unknown

  if [ -r /etc/os-release ]; then
    . /etc/os-release
    os_id=${ID:-unknown}
    os_version=${VERSION_ID:-unknown}
  fi

  root_free_kb=$(df -Pk / | awk "NR==2 {print \$4}")
  [ -n "$root_free_kb" ] || root_free_kb=unknown

  mem_available_kb=$(awk "/^MemAvailable:/ {print \$2; exit}" /proc/meminfo 2>/dev/null)
  [ -n "$mem_available_kb" ] || mem_available_kb=unknown

  printf "os_id=%s os_version=%s root_free_kb=%s mem_available_kb=%s\n" \
    "$os_id" "$os_version" "$root_free_kb" "$mem_available_kb"
' </dev/null)" || fail "OS inspection failed for LXC $vmid"

printf 'vmid=%s %s\n' "$vmid" "$result"
