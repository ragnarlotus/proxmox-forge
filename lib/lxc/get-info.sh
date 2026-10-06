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

parse_record() {
  local record="$1"
  local field key

  RECORD_FIELDS=()
  for field in $record; do
    [[ "$field" == *=* ]] || continue
    key="${field%%=*}"
    RECORD_FIELDS["$key"]="${field#*=}"
  done
}

declare -A RECORD_FIELDS=()

[[ $# -ge 1 && $# -le 2 ]] || fail "usage: get-info.sh VMID_OR_NAME [all]"
target="$1"
mode="${2:-}"

[[ -n "$target" ]] || fail "target must not be empty"
[[ -z "$mode" || "$mode" == all ]] || fail "unsupported information mode '$mode'; expected 'all'"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine lib directory"
target_script="$script_dir/get-target.sh"
config_get_script="$lib_dir/config/get.sh"

for helper in "$target_script" "$config_get_script"; do
  [[ -r "$helper" ]] || fail "LXC helper is not readable: $helper"
done

target_record="$(bash "$target_script" "$target")" || fail "could not resolve LXC target '$target'"
parse_record "$target_record"
vmid="${RECORD_FIELDS[vmid]:-}"
name="${RECORD_FIELDS[name]:-}"
state="${RECORD_FIELDS[state]:-}"
template="${RECORD_FIELDS[template]:-}"
[[ -n "$vmid" ]] || fail "LXC target helper returned no vmid"
[[ -n "$name" ]] || fail "LXC target helper returned no name"
[[ -n "$state" ]] || fail "LXC target helper returned no state"
[[ -n "$template" ]] || fail "LXC target helper returned no template field"

[[ "$template" == false ]] || fail "LXC $vmid ($name) is a template and cannot be inspected as an update target"
[[ "$state" == running ]] || fail "LXC $vmid ($name) is $state; information collection requires a running container"

package_record="$(pct exec "$vmid" -- sh -c '
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
' </dev/null)" || fail "package-manager inspection failed for LXC $vmid ($name)"

parse_record "$package_record"
package_manager="${RECORD_FIELDS[package_manager]:-}"
dpkg_audit="${RECORD_FIELDS[dpkg_audit]:-}"
package_process="${RECORD_FIELDS[package_process]:-}"
[[ -n "$package_manager" ]] || fail "package-manager inspection returned no package_manager"
[[ -n "$dpkg_audit" ]] || fail "package-manager inspection returned no dpkg_audit"
[[ -n "$package_process" ]] || fail "package-manager inspection returned no package_process"

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
  printf 'type=lxc vmid=%s name=%s state=%s template=false package_manager=%s dpkg_audit=%s package_process=%s custom_script=%s\n' \
    "$vmid" "$name" "$state" "$package_manager" "$dpkg_audit" "$package_process" "$custom_script"
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

  if [ -x /usr/bin/update ]; then
    application_updater=/usr/bin/update
  else
    application_updater=none
  fi

  printf "os_id=%s os_version=%s root_free_kb=%s mem_available_kb=%s application_updater=%s\n" \
    "$os_id" "$os_version" "$root_free_kb" "$mem_available_kb" "$application_updater"
' </dev/null)" || fail "OS/resource inspection failed for LXC $vmid"

parse_record "$os_record"
os_id="${RECORD_FIELDS[os_id]:-}"
os_version="${RECORD_FIELDS[os_version]:-}"
root_free_kb="${RECORD_FIELDS[root_free_kb]:-}"
mem_available_kb="${RECORD_FIELDS[mem_available_kb]:-}"
application_updater="${RECORD_FIELDS[application_updater]:-}"
[[ -n "$os_id" ]] || fail "OS inspection returned no os_id"
[[ -n "$os_version" ]] || fail "OS inspection returned no os_version"
[[ -n "$root_free_kb" ]] || fail "OS inspection returned no root_free_kb"
[[ -n "$mem_available_kb" ]] || fail "OS inspection returned no mem_available_kb"
[[ -n "$application_updater" ]] || fail "OS inspection returned no application_updater"

printf 'type=lxc vmid=%s name=%s state=%s template=false os_id=%s os_version=%s root_free_kb=%s mem_available_kb=%s package_manager=%s dpkg_audit=%s package_process=%s application_updater=%s custom_script=%s\n' \
  "$vmid" "$name" "$state" "$os_id" "$os_version" "$root_free_kb" "$mem_available_kb" \
  "$package_manager" "$dpkg_audit" "$package_process" "$application_updater" "$custom_script"
