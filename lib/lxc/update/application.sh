#!/bin/bash
# Description: Runs the supported application updater of one running LXC when present; it does not perform logging or orchestration.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: application.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

command -v pct >/dev/null 2>&1 || fail "pct is not available"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine update script directory"
lxc_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine LXC directory"
updater_script="$lxc_dir/get-application-updater.sh"
field_script="$lxc_dir/get-field.sh"

for helper in "$updater_script" "$field_script"; do
  [[ -r "$helper" ]] || fail "required helper is not readable: $helper"
done

updater_record="$(bash "$updater_script" "$vmid")" || \
  fail "could not determine application updater for LXC $vmid"
application_updater="$(bash "$field_script" "$updater_record" application_updater)" || \
  fail "application-updater record returned no application_updater"

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
