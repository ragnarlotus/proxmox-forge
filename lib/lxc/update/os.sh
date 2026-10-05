#!/bin/bash
# Description: Updates the operating-system packages of one running LXC using a supplied or detected supported package manager; it does not perform logging or orchestration.

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

run_update_command() {
  local description="$1"
  shift

  "$@"
  local result=$?

  if (( result != 0 )); then
    printf 'ERROR: %s failed for LXC %s (exit code: %s)\n' \
      "$description" "$vmid" "$result" >&2
    exit "$result"
  fi
}

[[ $# -ge 1 && $# -le 2 ]] || fail "usage: os.sh VMID [PACKAGE_MANAGER]"
vmid="$1"
package_manager="${2:-}"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

command -v pct >/dev/null 2>&1 || fail "pct is not available"

if [[ -z "$package_manager" ]]; then
  package_manager="$(pct exec "$vmid" -- sh -c '
    if command -v apt-get >/dev/null 2>&1; then
      printf apt
    elif command -v dnf >/dev/null 2>&1; then
      printf dnf
    elif command -v yum >/dev/null 2>&1; then
      printf yum
    elif command -v apk >/dev/null 2>&1; then
      printf apk
    elif command -v pacman >/dev/null 2>&1; then
      printf pacman
    else
      printf unknown
    fi
  ' </dev/null)" || fail "could not determine package manager for LXC $vmid"
fi

case "$package_manager" in
  apt)
    run_update_command "apt-get update" \
      pct exec "$vmid" -- \
        env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
        apt-get update </dev/null

    run_update_command "apt-get dist-upgrade" \
      pct exec "$vmid" -- \
        env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
        apt-get -y \
          -o Dpkg::Options::=--force-confdef \
          -o Dpkg::Options::=--force-confold \
          dist-upgrade </dev/null

    run_update_command "apt-get autoremove" \
      pct exec "$vmid" -- \
        env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
        apt-get -y \
          -o Dpkg::Options::=--force-confdef \
          -o Dpkg::Options::=--force-confold \
          autoremove </dev/null
    ;;
  dnf)
    run_update_command "dnf upgrade" \
      pct exec "$vmid" -- dnf -y upgrade </dev/null
    ;;
  yum)
    run_update_command "yum update" \
      pct exec "$vmid" -- yum -y update </dev/null
    ;;
  apk)
    run_update_command "apk update" \
      pct exec "$vmid" -- apk update </dev/null
    run_update_command "apk upgrade" \
      pct exec "$vmid" -- apk upgrade </dev/null
    ;;
  pacman)
    run_update_command "pacman update" \
      pct exec "$vmid" -- pacman -Syu --noconfirm </dev/null
    ;;
  *)
    fail "LXC $vmid has unsupported package manager '$package_manager'"
    ;;
esac

printf 'os_update=success vmid=%s package_manager=%s\n' "$vmid" "$package_manager"
