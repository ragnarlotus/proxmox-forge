#!/bin/bash

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: lxc-preflight.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

command -v pct >/dev/null 2>&1 || fail "pct is not available"
[[ -f "/etc/pve/lxc/${vmid}.conf" ]] || fail "LXC $vmid does not exist"

state="$(pct status "$vmid")" || fail "could not read state for LXC $vmid"
state="${state#status: }"
[[ "$state" == running ]] || fail "LXC $vmid is $state; preflight currently requires a running container"

result="$(pct exec "$vmid" -- sh -c '
  set -u

  os_id=unknown
  os_version=unknown
  package_manager=unknown
  application_updater=none
  dpkg_audit=not_applicable
  package_process=none

  if [ -r /etc/os-release ]; then
    . /etc/os-release
    os_id=${ID:-unknown}
    os_version=${VERSION_ID:-unknown}
  fi

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

  if [ -x /usr/bin/update ]; then
    application_updater=/usr/bin/update
  fi

  root_free_kb=$(df -Pk / | awk "NR==2 {print \$4}")
  [ -n "$root_free_kb" ] || root_free_kb=unknown

  mem_available_kb=$(awk "/^MemAvailable:/ {print \$2; exit}" /proc/meminfo 2>/dev/null)
  [ -n "$mem_available_kb" ] || mem_available_kb=unknown

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

  printf "os_id=%s os_version=%s package_manager=%s application_updater=%s root_free_kb=%s mem_available_kb=%s dpkg_audit=%s package_process=%s\n" \
    "$os_id" "$os_version" "$package_manager" "$application_updater" \
    "$root_free_kb" "$mem_available_kb" "$dpkg_audit" "$package_process"
' </dev/null)" || fail "read-only preflight inspection failed for LXC $vmid"

printf 'vmid=%s state=%s %s\n' "$vmid" "$state" "$result"

case " $result " in
  *" package_manager=unknown "*) fail "LXC $vmid has no supported package manager" ;;
esac

case " $result " in
  *" dpkg_audit=issues "*) fail "LXC $vmid has dpkg audit issues" ;;
  *" dpkg_audit=error "*) fail "LXC $vmid dpkg audit could not complete" ;;
esac

case " $result " in
  *" package_process=none "*) ;;
  *) fail "LXC $vmid has an active package-manager process" ;;
esac

printf 'preflight=ok vmid=%s\n' "$vmid"
