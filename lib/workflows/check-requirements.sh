#!/bin/bash
# Description: Performs read-only checks that determine whether an LXC satisfies the current requirements to begin an update; it never creates backups or mutates the target.

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

[[ $# -eq 1 ]] || fail "usage: check-requirements.sh VMID_OR_NAME"
target="$1"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine lib directory"
info_script="$lib_dir/lxc/get-info.sh"

[[ -r "$info_script" ]] || fail "required helper is not readable: $info_script"

info="$(bash "$info_script" "$target")" || fail "could not collect LXC information for '$target'"
printf '%s\n' "$info"

declare -A info_fields=()
for field in $info; do
  [[ "$field" == *=* ]] || continue
  key="${field%%=*}"
  info_fields["$key"]="${field#*=}"
done

vmid="${info_fields[vmid]:-}"
name="${info_fields[name]:-}"
state="${info_fields[state]:-}"
template="${info_fields[template]:-}"
package_manager="${info_fields[package_manager]:-}"
dpkg_audit="${info_fields[dpkg_audit]:-}"
package_process="${info_fields[package_process]:-}"
custom_script="${info_fields[custom_script]:-}"

[[ -n "$vmid" ]] || fail "LXC information returned no vmid"
[[ -n "$name" ]] || fail "LXC information returned no name"
[[ -n "$state" ]] || fail "LXC information returned no state"
[[ -n "$template" ]] || fail "LXC information returned no template"
[[ -n "$package_manager" ]] || fail "LXC information returned no package_manager"
[[ -n "$dpkg_audit" ]] || fail "LXC information returned no dpkg_audit"
[[ -n "$package_process" ]] || fail "LXC information returned no package_process"
[[ "$custom_script" == true || "$custom_script" == false ]] || fail "LXC information returned invalid custom_script"

[[ "$package_manager" != unknown ]] || fail "LXC $vmid has no supported package manager"

case "$dpkg_audit" in
  issues) fail "LXC $vmid has dpkg audit issues" ;;
  error) fail "LXC $vmid dpkg audit could not complete" ;;
esac

[[ "$package_process" == none ]] || fail "LXC $vmid has an active package-manager process: $package_process"

printf 'requirements=ok vmid=%s name=%s state=%s template=%s package_manager=%s custom_script=%s\n' \
  "$vmid" "$name" "$state" "$template" "$package_manager" "$custom_script"
