#!/bin/bash
# Description: Updates local Proxmox VE host packages non-interactively with APT; it does not perform logging, recovery, or orchestration.

set -u

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
    printf 'ERROR: %s failed for Proxmox host (exit code: %s)\n' \
      "$description" "$result" >&2
    exit "$result"
  fi
}

[[ $# -eq 0 ]] || fail "os.sh does not accept arguments"
command -v apt-get >/dev/null 2>&1 || fail "apt-get is not available"

run_update_command "apt-get update" \
  env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
    apt-get update

run_update_command "apt-get full-upgrade" \
  env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a \
    apt-get -y \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      full-upgrade

printf 'host_os_update=success\n'
