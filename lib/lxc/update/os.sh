#!/bin/bash
# Description: Updates the operating-system packages of one running LXC using its detected supported package manager; it does not perform logging or orchestration.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: os.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

command -v pct >/dev/null 2>&1 || fail "pct is not available"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine update script directory"
lxc_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine LXC directory"
package_manager_script="$lxc_dir/get-package-manager.sh"
field_script="$lxc_dir/get-field.sh"

for helper in "$package_manager_script" "$field_script"; do
  [[ -r "$helper" ]] || fail "required helper is not readable: $helper"
done

package_record="$(bash "$package_manager_script" "$vmid")" || \
  fail "could not determine package manager for LXC $vmid"
package_manager="$(bash "$field_script" "$package_record" package_manager)" || \
  fail "package-manager record returned no package_manager"

case "$package_manager" in
  apt)
    pct exec "$vmid" -- \
      env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
      apt-get update </dev/null || \
      fail "apt-get update failed for LXC $vmid"

    pct exec "$vmid" -- \
      env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
      apt-get -y \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        dist-upgrade </dev/null || \
      fail "apt-get dist-upgrade failed for LXC $vmid"
    ;;
  dnf)
    pct exec "$vmid" -- dnf -y upgrade </dev/null || \
      fail "dnf upgrade failed for LXC $vmid"
    ;;
  yum)
    pct exec "$vmid" -- yum -y update </dev/null || \
      fail "yum update failed for LXC $vmid"
    ;;
  apk)
    pct exec "$vmid" -- apk update </dev/null || \
      fail "apk update failed for LXC $vmid"
    pct exec "$vmid" -- apk upgrade </dev/null || \
      fail "apk upgrade failed for LXC $vmid"
    ;;
  pacman)
    pct exec "$vmid" -- pacman -Syu --noconfirm </dev/null || \
      fail "pacman update failed for LXC $vmid"
    ;;
  *)
    fail "LXC $vmid has unsupported package manager '$package_manager'"
    ;;
esac

printf 'os_update=success vmid=%s package_manager=%s\n' "$vmid" "$package_manager"
