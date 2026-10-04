#!/bin/bash
# Description: Returns the complete available information for one running LXC, combining target identity, OS/resources, package-manager state, application updater, and Forge custom-script presence.

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

[[ $# -eq 2 ]] || fail "usage: get-info.sh VMID_OR_NAME CUSTOM_SCRIPTS_DIR"
target="$1"
custom_scripts_dir="$2"
[[ -n "$target" ]] || fail "target must not be empty"
[[ "$custom_scripts_dir" == /* ]] || fail "CUSTOM_SCRIPTS_DIR must be an absolute path"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
target_script="$script_dir/get-target.sh"
field_script="$script_dir/get-field.sh"
package_script="$script_dir/get-package-manager.sh"
updater_script="$script_dir/get-application-updater.sh"

for helper in "$target_script" "$field_script" "$package_script" "$updater_script"; do
  [[ -r "$helper" ]] || fail "LXC helper is not readable: $helper"
done

target_record="$(bash "$target_script" "$target")" || fail "could not resolve LXC target '$target'"
vmid="$(bash "$field_script" "$target_record" vmid)" || fail "LXC target helper returned no vmid"
name="$(bash "$field_script" "$target_record" name)" || fail "LXC target helper returned no name"
state="$(bash "$field_script" "$target_record" state)" || fail "LXC target helper returned no state"
template="$(bash "$field_script" "$target_record" template)" || fail "LXC target helper returned no template field"

[[ "$template" == false ]] || fail "LXC $vmid ($name) is a template and cannot be inspected as an update target"
[[ "$state" == running ]] || fail "LXC $vmid ($name) is $state; information collection requires a running container"

os_record="$(pct exec "$vmid" -- sh -c '
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
' </dev/null)" || fail "OS/resource inspection failed for LXC $vmid"

package_record="$(bash "$package_script" "$vmid")" || fail "could not read package-manager information for LXC $vmid ($name)"
updater_record="$(bash "$updater_script" "$vmid")" || fail "could not read application-updater information for LXC $vmid ($name)"

os_id="$(bash "$field_script" "$os_record" os_id)" || fail "OS inspection returned no os_id"
os_version="$(bash "$field_script" "$os_record" os_version)" || fail "OS inspection returned no os_version"
root_free_kb="$(bash "$field_script" "$os_record" root_free_kb)" || fail "OS inspection returned no root_free_kb"
mem_available_kb="$(bash "$field_script" "$os_record" mem_available_kb)" || fail "OS inspection returned no mem_available_kb"
package_manager="$(bash "$field_script" "$package_record" package_manager)" || fail "package-manager helper returned no package_manager"
dpkg_audit="$(bash "$field_script" "$package_record" dpkg_audit)" || fail "package-manager helper returned no dpkg_audit"
package_process="$(bash "$field_script" "$package_record" package_process)" || fail "package-manager helper returned no package_process"
application_updater="$(bash "$field_script" "$updater_record" application_updater)" || fail "application-updater helper returned no application_updater"

custom_script=false
if [[ -d "$custom_scripts_dir/$vmid" ]] &&
   find "$custom_scripts_dir/$vmid" -maxdepth 1 -type f -print -quit 2>/dev/null | grep -q .; then
  custom_script=true
fi

printf 'type=lxc vmid=%s name=%s state=%s template=false os_id=%s os_version=%s root_free_kb=%s mem_available_kb=%s package_manager=%s dpkg_audit=%s package_process=%s application_updater=%s custom_script=%s\n' \
  "$vmid" "$name" "$state" "$os_id" "$os_version" "$root_free_kb" "$mem_available_kb" \
  "$package_manager" "$dpkg_audit" "$package_process" "$application_updater" "$custom_script"
