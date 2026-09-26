#!/bin/bash
# Description: Removes old timestamped Forge LXC logs for one VMID on the local Proxmox host while keeping the configured number of most recent attempts.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 4 ]] || fail "usage: prune.sh LOG_DIR LOG_KEEP SCOPE IDENTIFIER"
log_dir="$1"
log_keep="$2"
scope="$3"
identifier="$4"

[[ "$log_dir" == /* ]] || fail "LOG_DIR must be an absolute path"
[[ "$log_keep" =~ ^[1-9][0-9]*$ ]] || fail "LOG_KEEP must be a positive integer"
[[ "$scope" == lxc ]] || fail "log retention currently applies only to LXC logs"
[[ "$identifier" =~ ^[0-9]+$ ]] || fail "LXC log identifier must be a numeric VMID"
command -v hostname >/dev/null 2>&1 || fail "hostname is not available"

pve_fqdn="$(hostname -f 2>/dev/null)" || fail "could not determine Proxmox host FQDN"
[[ "$pve_fqdn" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid Proxmox host FQDN '$pve_fqdn'"

target_dir="$log_dir/$pve_fqdn/lxc/$identifier"
[[ -d "$target_dir" ]] || exit 0

mapfile -t logs < <(
  find "$target_dir" -maxdepth 1 -type f -name '*.log' -printf '%f\n' | LC_ALL=C sort -r
)

for ((i = log_keep; i < ${#logs[@]}; i++)); do
  rm -f -- "$target_dir/${logs[i]}" || fail "could not remove old log: $target_dir/${logs[i]}"
done
