#!/bin/bash
# Description: Returns the package/update information required by LXC requirements checks, or complete LXC information with 'all', reusing an already-resolved target record when supplied.

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

[[ $# -ge 1 && $# -le 3 ]] || fail "usage: get-info.sh VMID_OR_NAME [all] [TARGET_RECORD]"
target="$1"
mode="${2:-}"
target_record="${3:-}"

[[ -n "$target" ]] || fail "target must not be empty"
[[ -z "$mode" || "$mode" == all ]] || fail "unsupported information mode '$mode'; expected 'all'"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
target_script="$script_dir/get-target.sh"
[[ -r "$target_script" ]] || fail "LXC target helper is not readable: $target_script"

if [[ -z "$target_record" ]]; then
  target_record="$(bash "$target_script" "$target")" || fail "could not resolve LXC target '$target'"
fi

parse_record "$target_record"
record_type="${RECORD_FIELDS[type]:-}"
vmid="${RECORD_FIELDS[vmid]:-}"
name="${RECORD_FIELDS[name]:-}"
state="${RECORD_FIELDS[state]:-}"
template="${RECORD_FIELDS[template]:-}"
[[ "$record_type" == lxc ]] || fail "LXC target record returned invalid type '$record_type'"
[[ -n "$vmid" ]] || fail "LXC target helper returned no vmid"
[[ -n "$name" ]] || fail "LXC target helper returned no name"
[[ -n "$state" ]] || fail "LXC target helper returned no state"
[[ -n "$template" ]] || fail "LXC target helper returned no template field"
[[ "$target" == "$vmid" || "$target" == "$name" ]] || \
  fail "LXC target record does not match requested target '$target'"

[[ "$template" == false ]] || fail "LXC $vmid ($name) is a template and cannot be inspected as an update target"
[[ "$state" == running ]] || fail "LXC $vmid ($name) is $state; information collection requires a running container"

info_record="$(pct exec "$vmid" -- env FORGE_INFO_MODE="$mode" sh -c '
  set -u

  package_manager=unknown
  dpkg_audit=not_applicable
  package_process=none

  if command -v apt-get >/dev/null 2>&1; then
    package_manager=apt
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

  if [ -x /usr/bin/update ]; then
    application_updater=/usr/bin/update
  else
    application_updater=none
  fi

  printf "package_manager=%s dpkg_audit=%s package_process=%s application_updater=%s root_free_kb=%s" \
    "$package_manager" "$dpkg_audit" "$package_process" "$application_updater" "$root_free_kb"

  root_free_kb=$(df -Pk / | awk "NR==2 {print \$4}")
  [ -n "$root_free_kb" ] || root_free_kb=unknown

  if [ "${FORGE_INFO_MODE:-}" = all ]; then
    os_id=unknown
    os_version=unknown

    if [ -r /etc/os-release ]; then
      . /etc/os-release
      os_id=${ID:-unknown}
      os_version=${VERSION_ID:-unknown}
    fi

    mem_available_kb=$(awk "/^MemAvailable:/ {print \$2; exit}" /proc/meminfo 2>/dev/null)
    [ -n "$mem_available_kb" ] || mem_available_kb=unknown

    printf " os_id=%s os_version=%s root_free_kb=%s mem_available_kb=%s" \
      "$os_id" "$os_version" "$root_free_kb" "$mem_available_kb"
  fi

  printf "\n"
' </dev/null)" || fail "LXC inspection failed for LXC $vmid ($name)"

parse_record "$info_record"
package_manager="${RECORD_FIELDS[package_manager]:-}"
dpkg_audit="${RECORD_FIELDS[dpkg_audit]:-}"
package_process="${RECORD_FIELDS[package_process]:-}"
application_updater="${RECORD_FIELDS[application_updater]:-}"
root_free_kb="${RECORD_FIELDS[root_free_kb]:-}"
[[ -n "$root_free_kb" ]] || fail "LXC inspection returned no root_free_kb"
[[ -n "$package_manager" ]] || fail "LXC inspection returned no package_manager"
[[ -n "$dpkg_audit" ]] || fail "LXC inspection returned no dpkg_audit"
[[ -n "$package_process" ]] || fail "LXC inspection returned no package_process"
[[ -n "$application_updater" ]] || fail "LXC inspection returned no application_updater"

if [[ "$mode" != all ]]; then
  printf 'type=lxc vmid=%s name=%s state=%s template=false package_manager=%s dpkg_audit=%s package_process=%s application_updater=%s root_free_kb=%s\n' \
    "$vmid" "$name" "$state" "$package_manager" "$dpkg_audit" "$package_process" "$application_updater" "$root_free_kb"
  exit 0
fi

os_id="${RECORD_FIELDS[os_id]:-}"
os_version="${RECORD_FIELDS[os_version]:-}"
mem_available_kb="${RECORD_FIELDS[mem_available_kb]:-}"
[[ -n "$os_id" ]] || fail "LXC inspection returned no os_id"
[[ -n "$os_version" ]] || fail "LXC inspection returned no os_version"
[[ -n "$root_free_kb" ]] || fail "LXC inspection returned no root_free_kb"
[[ -n "$mem_available_kb" ]] || fail "LXC inspection returned no mem_available_kb"

printf 'type=lxc vmid=%s name=%s state=%s template=false os_id=%s os_version=%s root_free_kb=%s mem_available_kb=%s package_manager=%s dpkg_audit=%s package_process=%s application_updater=%s\n' \
  "$vmid" "$name" "$state" "$os_id" "$os_version" "$root_free_kb" "$mem_available_kb" \
  "$package_manager" "$dpkg_audit" "$package_process" "$application_updater"
