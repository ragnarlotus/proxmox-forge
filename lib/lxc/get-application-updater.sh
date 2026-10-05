#!/bin/bash
# Description: Detects whether one running LXC exposes the Community Scripts application updater at /usr/bin/update.

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

[[ $# -eq 1 ]] || fail "usage: get-application-updater.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

application_updater="$(pct exec "$vmid" -- sh -c '
  if [ -x /usr/bin/update ]; then
    printf "/usr/bin/update"
  else
    printf "none"
  fi
' </dev/null)" || fail "application-updater inspection failed for LXC $vmid"

printf 'vmid=%s application_updater=%s\n' "$vmid" "$application_updater"
