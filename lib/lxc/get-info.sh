#!/bin/bash
# Description: Returns the package/update information required by LXC preflight, or the complete available LXC information when explicitly requested with 'all'.

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

[[ $# -ge 1 && $# -le 2 ]] || fail "usage: get-info.sh VMID_OR_NAME [all]"
target="$1"
mode="${2:-}"

[[ -n "$target" ]] || fail "target must not be empty"
[[ -z "$mode" || "$mode" == all ]] || fail "unsupported information mode '$mode'; expected 'all'"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine lib directory"
target_script="$script_dir/get-target.sh"
field_script="$script_dir/get-field.sh"
package_script="$script_dir/get-package-manager.sh"
updater_script="$script_dir/get-application-updater.sh"
config_get_script="$lib_dir/config/get.sh"

for helper in "$target_script" "$field_script" "$package_script" "$config_get_script"; do
  [[ -r "$helper" ]] || fail "LXC helper is not readable: $helper"
done

if [[ "$mode" == all ]]; then
  [[ -r "$updater_script" ]] || fail "LXC helper is not readable: $updater_script"
fi

target_record="$(bash "$target_script" "$target")" || fail "could not resolve LXC target '$target'"
vmid="$(bash "$field_script" "$target_record" vmid)" || fail "LXC target helper returned no vmid"
name="$(bash "$field_script" "$target_record" name)" || fail "LXC target helper returned no name"
state="$(bash "$field_script" "$target_record" state)" || fail "LXC target helper returned no state"
template="$(bash "$field_script" "$target_record" template)" || fail "LXC target helper returned no template field"

[[ "$template" == false ]] || fail "LXC $vmid ($name) is a template and cannot be inspected as an update target"
[[ "$state" == running ]] || fail "LXC $vmid ($name) is $state; information collection requires a running container"

package_record="$(bash "$package_script" "$vmid")" || fail "could not read package-manager information for LXC $vmid ($name)"
package_manager="$(bash "$field_script" "$package_record" package_manager)" || fail "package-manager helper returned no package_manager"
dpkg_audit="$(bash "$field_script" "$package_record" dpkg_audit)" || fail "package-manager helper returned no dpkg_audit"
package_process="$(bash "$field_script" "$package_record" package_process)" || fail "package-manager helper returned no package_process"

# shellcheck source=/dev/null
source "$config_get_script" || fail "could not load config helpers"
config_get || fail "could not load effective Forge configuration"
custom_scripts_dir="${CONFIG[CUSTOM_SCRIPTS_DIR]}"

custom_script=false
if [[ -d "$custom_scripts_dir/$vmid" ]] &&
   find "$custom_scripts_dir/$vmid" -maxdepth 1 -type f -name '*.sh' -print -quit 2>/dev/null | grep -q .; then
  custom_script=true
fi

if [[ "$mode" != all ]]; then
  printf 'vmid=%s package_manager=%s dpkg_audit=%s package_process=%s custom_script=%s\n' \
    "$vmid" "$package_manager" "$dpkg_audit" "$package_process" "$custom_script"
  exit 0
fi

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

updater_record="$(bash "$updater_script" "$vmid")" || fail "could not read application-updater information for LXC $vmid ($name)"

os_id="$(bash "$field_script" "$os_record" os_id)" || fail "OS inspection returned no os_id"
os_version="$(bash "$field_script" "$os_record" os_version)" || fail "OS inspection returned no os_version"
root_free_kb="$(bash "$field_script" "$os_record" root_free_kb)" || fail "OS inspection returned no root_free_kb"
mem_available_kb="$(bash "$field_script" "$os_record" mem_available_kb)" || fail "OS inspection returned no mem_available_kb"
application_updater="$(bash "$field_script" "$updater_record" application_updater)" || fail "application-updater helper returned no application_updater"

printf 'type=lxc vmid=%s name=%s state=%s template=false os_id=%s os_version=%s root_free_kb=%s mem_available_kb=%s package_manager=%s dpkg_audit=%s package_process=%s application_updater=%s custom_script=%s\n' \
  "$vmid" "$name" "$state" "$os_id" "$os_version" "$root_free_kb" "$mem_available_kb" \
  "$package_manager" "$dpkg_audit" "$package_process" "$application_updater" "$custom_script"
