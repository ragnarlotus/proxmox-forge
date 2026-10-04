#!/bin/bash
# Description: Detects the supported package manager in one running LXC and reports package-manager health checks relevant to safe updates.

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

[[ $# -eq 1 ]] || fail "usage: get-package-manager.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
state_script="$script_dir/get-state.sh"
[[ -r "$state_script" ]] || fail "LXC state helper is not readable: $state_script"

state="$(bash "$state_script" "$vmid")" || fail "could not read state for LXC $vmid"
[[ "$state" == running ]] || fail "LXC $vmid is $state; package-manager inspection requires a running container"

result="$(pct exec "$vmid" -- sh -c '
  set -u

  package_manager=unknown
  dpkg_audit=not_applicable
  package_process=none

  if command -v apt-get >/dev/null 2>&1; then
    package_manager=apt
  elif command -v dnf >/dev/null 2>&1; then
    package_manager=dnf
  elif command -v yum >/dev/null 2>&1; then
    package_manager=yum
  elif command -v apk >/dev/null 2>&1; then
    package_manager=apk
  elif command -v pacman >/dev/null 2>&1; then
    package_manager=pacman
  fi

  if [ "$package_manager" = apt ]; then
    if audit=$(dpkg --audit 2>&1); then
      if [ -n "$audit" ]; then
        dpkg_audit=issues
      else
        dpkg_audit=clean
      fi
    else
      dpkg_audit=error
    fi

    package_process=$(ps -eo comm= 2>/dev/null | awk "\$1 ~ /^(apt|apt-get|dpkg|unattended-upgr)$/ {print \$1; exit}")
    [ -n "$package_process" ] || package_process=none
  fi

  printf "package_manager=%s dpkg_audit=%s package_process=%s\n" \
    "$package_manager" "$dpkg_audit" "$package_process"
' </dev/null)" || fail "package-manager inspection failed for LXC $vmid"

printf 'vmid=%s %s\n' "$vmid" "$result"
