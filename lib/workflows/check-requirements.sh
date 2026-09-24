#!/bin/bash
# Description: Performs read-only checks that determine whether an LXC satisfies the current requirements to begin an update; it never creates backups or mutates the target.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 2 ]] || fail "usage: check-requirements.sh VMID_OR_NAME CUSTOM_SCRIPTS_DIR"
target="$1"
custom_scripts_dir="$2"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine lib directory"
info_script="$lib_dir/lxc/get-info.sh"
field_script="$lib_dir/lxc/get-field.sh"

for helper in "$info_script" "$field_script"; do
  [[ -r "$helper" ]] || fail "required helper is not readable: $helper"
done

info="$(bash "$info_script" "$target" "$custom_scripts_dir")" || fail "could not collect LXC information for '$target'"
printf '%s\n' "$info"

vmid="$(bash "$field_script" "$info" vmid)" || fail "LXC information returned no vmid"
package_manager="$(bash "$field_script" "$info" package_manager)" || fail "LXC information returned no package_manager"
dpkg_audit="$(bash "$field_script" "$info" dpkg_audit)" || fail "LXC information returned no dpkg_audit"
package_process="$(bash "$field_script" "$info" package_process)" || fail "LXC information returned no package_process"

[[ "$package_manager" != unknown ]] || fail "LXC $vmid has no supported package manager"

case "$dpkg_audit" in
  issues) fail "LXC $vmid has dpkg audit issues" ;;
  error) fail "LXC $vmid dpkg audit could not complete" ;;
esac

[[ "$package_process" == none ]] || fail "LXC $vmid has an active package-manager process: $package_process"

printf 'requirements=ok vmid=%s\n' "$vmid"
