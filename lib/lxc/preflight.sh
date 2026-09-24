#!/bin/bash
# Description: Orchestrates read-only LXC readiness checks and blocks the update flow when required preflight conditions are not satisfied.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

field_value() {
  local record="$1" wanted="$2" field

  for field in $record; do
    if [[ "$field" == "$wanted="* ]]; then
      printf '%s' "${field#*=}"
      return 0
    fi
  done

  return 1
}

[[ $# -eq 1 ]] || fail "usage: preflight.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
running_script="$script_dir/get-running.sh"
so_script="$script_dir/get-so-info.sh"
package_script="$script_dir/get-package-manager.sh"
updater_script="$script_dir/get-application-updater.sh"

for helper in "$running_script" "$so_script" "$package_script" "$updater_script"; do
  [[ -r "$helper" ]] || fail "LXC helper is not readable: $helper"
done

running_record="$(bash "$running_script" "$vmid")" || fail "could not read running state for LXC $vmid"
running="$(field_value "$running_record" running)" || fail "running-state helper returned no running field"
state="$(field_value "$running_record" state)" || fail "running-state helper returned no state field"
[[ "$running" == true ]] || fail "LXC $vmid is $state; preflight requires a running container"

so_record="$(bash "$so_script" "$vmid")" || fail "could not read OS information for LXC $vmid"
package_record="$(bash "$package_script" "$vmid")" || fail "could not read package-manager information for LXC $vmid"
updater_record="$(bash "$updater_script" "$vmid")" || fail "could not read application-updater information for LXC $vmid"

os_id="$(field_value "$so_record" os_id)" || fail "OS helper returned no os_id"
os_version="$(field_value "$so_record" os_version)" || fail "OS helper returned no os_version"
root_free_kb="$(field_value "$so_record" root_free_kb)" || fail "OS helper returned no root_free_kb"
mem_available_kb="$(field_value "$so_record" mem_available_kb)" || fail "OS helper returned no mem_available_kb"
package_manager="$(field_value "$package_record" package_manager)" || fail "package-manager helper returned no package_manager"
dpkg_audit="$(field_value "$package_record" dpkg_audit)" || fail "package-manager helper returned no dpkg_audit"
package_process="$(field_value "$package_record" package_process)" || fail "package-manager helper returned no package_process"
application_updater="$(field_value "$updater_record" application_updater)" || fail "application-updater helper returned no application_updater"

printf 'vmid=%s state=%s os_id=%s os_version=%s package_manager=%s application_updater=%s root_free_kb=%s mem_available_kb=%s dpkg_audit=%s package_process=%s\n' \
  "$vmid" "$state" "$os_id" "$os_version" "$package_manager" "$application_updater" \
  "$root_free_kb" "$mem_available_kb" "$dpkg_audit" "$package_process"

[[ "$package_manager" != unknown ]] || fail "LXC $vmid has no supported package manager"

case "$dpkg_audit" in
  issues) fail "LXC $vmid has dpkg audit issues" ;;
  error) fail "LXC $vmid dpkg audit could not complete" ;;
esac

[[ "$package_process" == none ]] || fail "LXC $vmid has an active package-manager process: $package_process"

printf 'preflight=ok vmid=%s\n' "$vmid"
