#!/bin/bash
# Description: Performs read-only requirements checks for the local Proxmox VE host before Forge host updates; it never mutates the host.

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

[[ $# -eq 0 ]] || fail "check-requirements.sh does not accept arguments"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine requirements directory"
lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine lib directory"
source "$lib_dir/config/get.sh" || fail "could not load config"
config_get || fail "could not load effective configuration"
root_space_script="$lib_dir/preflight/root-space.sh"
memory_script="$lib_dir/preflight/memory.sh"
[[ -r "$root_space_script" ]] || fail "root-space helper is not readable"
[[ -r "$memory_script" ]] || fail "memory helper is not readable"

for command_name in pveversion hostname uname dpkg ps df awk; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is not available: $command_name"
done

[[ -r /etc/os-release ]] || fail "/etc/os-release is not readable"

hostname_fqdn="$(hostname -f 2>/dev/null)" || fail "could not determine host FQDN"
kernel="$(uname -r)" || fail "could not determine running kernel"
pve_version="$(pveversion | awk -F'[/ ]' 'NR == 1 { print $2; exit }')" || fail "could not determine Proxmox VE version"
os_id="$(awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2; exit }' /etc/os-release)"
os_version="$(awk -F= '$1 == "VERSION_ID" { gsub(/"/, "", $2); print $2; exit }' /etc/os-release)"
root_free_kb="$(df -Pk / | awk 'NR == 2 { print $4; exit }')" || fail "could not determine root filesystem free space"
mem_available_kb="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)" || fail "could not determine host available memory"

[[ -n "$hostname_fqdn" ]] || fail "host FQDN is empty"
[[ -n "$kernel" ]] || fail "running kernel is empty"
[[ -n "$pve_version" ]] || fail "Proxmox VE version is empty"
[[ -n "$os_id" ]] || fail "operating-system ID is empty"
[[ -n "$os_version" ]] || fail "operating-system version is empty"
[[ "$root_free_kb" =~ ^[0-9]+$ ]] || fail "root filesystem free-space value is invalid"
bash "$root_space_script" host "${CONFIG[MIN_ROOT_FREE_MB]}" "$root_free_kb" || fail "host root space preflight failed"
bash "$memory_script" host "${CONFIG[MIN_MEM_AVAILABLE_MB]}" "$mem_available_kb" || fail "host memory preflight failed"

pve_major="${pve_version%%.*}"
[[ "$pve_major" == 9 ]] || fail "unsupported Proxmox VE major version '$pve_major'"
[[ "$os_id" == debian ]] || fail "unsupported host operating system '$os_id'"
[[ "$os_version" == 13 ]] || fail "unsupported Debian version '$os_version'"

dpkg_audit_output="$(dpkg --audit 2>&1)"
dpkg_audit_result=$?
if (( dpkg_audit_result != 0 )); then
  printf '%s\n' "$dpkg_audit_output" >&2
  fail "host dpkg audit could not complete"
fi
if [[ -n "$dpkg_audit_output" ]]; then
  printf '%s\n' "$dpkg_audit_output" >&2
  fail "host has dpkg audit issues"
fi

package_process="$(
  ps -eo comm= | awk '
    $1 == "apt" ||
    $1 == "apt-get" ||
    $1 == "dpkg" ||
    $1 == "unattended-upgr" ||
    $1 == "unattended-upgrade" {
      print $1
      exit
    }
  '
)" || fail "could not inspect package-manager processes"

[[ -z "$package_process" ]] || fail "host has an active package-manager process: $package_process"

printf 'type=host hostname=%s pve_version=%s os_id=%s os_version=%s kernel=%s root_free_kb=%s mem_available_kb=%s dpkg_audit=clean package_process=none\n' \
  "$hostname_fqdn" "$pve_version" "$os_id" "$os_version" "$kernel" "$root_free_kb" "$mem_available_kb"
printf 'requirements=ok type=host hostname=%s\n' "$hostname_fqdn"
