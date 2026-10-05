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

[[ $# -eq 1 ]] || fail "usage: application.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

command -v pct >/dev/null 2>&1 || fail "pct is not available"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine update script directory"
lxc_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine LXC directory"
updater_script="$lxc_dir/get-application-updater.sh"

[[ -r "$updater_script" ]] || fail "required helper is not readable: $updater_script"

updater_record="$(bash "$updater_script" "$vmid")" || \
  fail "could not determine application updater for LXC $vmid"
read -r vmid_field updater_field extra_field <<< "$updater_record"

[[ "$vmid_field" == vmid=* ]] || fail "application-updater record returned no vmid"
[[ "$updater_field" == application_updater=* ]] || fail "application-updater record returned no application_updater"
[[ -z "${extra_field:-}" ]] || fail "application-updater record returned unexpected fields"

record_vmid="${vmid_field#vmid=}"
application_updater="${updater_field#application_updater=}"
[[ "$record_vmid" == "$vmid" ]] || fail "application-updater record returned mismatched vmid '$record_vmid' for $vmid"

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
