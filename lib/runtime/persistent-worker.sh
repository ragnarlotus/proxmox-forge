#!/bin/bash
# F131: one tmux-pane wrapper. Preserve the exact updater exit code for an
# attached caller; all authoritative results stay in Forge's existing logs.
set -u

[[ $# -ge 3 ]] || {
  printf 'ERROR: persistent worker requires status file, Forge entry and update arguments\n' >&2
  exit 1
}
status_file="$1"
entry="$2"
shift 2

# Guard against a tmux socket race: if the systemd server vanished between
# the launcher's readiness check and new-session, tmux might create a fresh
# SSH-owned server. The worker must refuse ALL update mutations in that case.
unit="proxmox-forge-f131-$(id -u).service"
if [[ -r "/proc/$/cgroup" ]] &&
   grep -Fq "/system.slice/$unit" "/proc/$/cgroup"; then
  "$entry" "$@"
  result=$?
else
  printf 'ERROR: F131 updater is not running in its independent systemd service; update refused\n' >&2
  result=1
fi

# A private runtime directory is prepared and verified by the public launcher.
# An atomic rename prevents reading a partial or fabricated completion status.
tmp_file="$status_file.$$"
if (umask 077; printf '%s\n' "$result" > "$tmp_file") &&
   mv -f -- "$tmp_file" "$status_file"; then
  :
else
  printf 'WARNING: could not persist the update exit code; consult forge history\n' >&2
  rm -f -- "$tmp_file"
fi
exit "$result"
