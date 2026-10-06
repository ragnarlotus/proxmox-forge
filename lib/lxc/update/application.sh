#!/bin/bash
# Description: Runs the supported application updater of one running LXC when present; it does not perform logging or orchestration.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run mutating operations through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || fail "usage: application.sh VMID [APPLICATION_UPDATER]"
vmid="$1"
application_updater="${2:-}"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

command -v pct >/dev/null 2>&1 || fail "pct is not available"

if [[ -z "$application_updater" ]]; then
  application_updater="$(pct exec "$vmid" -- sh -c '
    if [ -x /usr/bin/update ]; then
      printf "/usr/bin/update"
    else
      printf "none"
    fi
  ' </dev/null)" || fail "could not determine application updater for LXC $vmid"
fi

case "$application_updater" in
  none)
    printf 'application_update=skipped vmid=%s reason=no_supported_updater\n' "$vmid"
    exit 0
    ;;
  /usr/bin/update)
    pct exec "$vmid" -- \
      env PHS_SILENT=1 /usr/bin/update </dev/null
    result=$?

    if (( result != 0 )); then
      printf 'ERROR: application updater failed for LXC %s (exit code: %s)\n' \
        "$vmid" "$result" >&2
      exit "$result"
    fi
    ;;
  *)
    fail "LXC $vmid returned unsupported application updater '$application_updater'"
    ;;
esac

printf 'application_update=success vmid=%s updater=%s\n' \
  "$vmid" "$application_updater"
