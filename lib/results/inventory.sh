#!/bin/bash
# Description: Inventory all local LXCs (including unselected ones) for final results.
# Read-only: does not change actual update selection.
set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run it through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 2 || $# -eq 3 ]] || fail "usage: inventory.sh UPDATE_RUNNING_LXC EXCLUDE [SCHEDULED_UPDATE_LXC]"
update_running="$1"
exclusions="$2"
scheduled_scope=false
scheduled_allowlist=""
if (( $# == 3 )); then
  scheduled_scope=true
  scheduled_allowlist="$3"
fi
[[ "$update_running" == true || "$update_running" == false ]] || fail "invalid running-LXC policy"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not resolve script directory"
exclude_script="$script_dir/../lxc/exclusions.sh"
[[ -r "$exclude_script" ]] || fail "exclusion helper is not readable"
# shellcheck source=/dev/null
source "$exclude_script" || fail "could not load exclusion helper"

[[ -d /etc/pve/lxc ]] || fail "Proxmox LXC inventory directory is unavailable"
command -v pct >/dev/null 2>&1 || fail "pct is not available"
command -v sort >/dev/null 2>&1 || fail "sort is not available"

shopt -s nullglob
configs=(/etc/pve/lxc/*.conf)
shopt -u nullglob
vmids=()
for file in "${configs[@]}"; do
  vmid="${file##*/}"
  vmid="${vmid%.conf}"
  [[ "$vmid" =~ ^[0-9]+$ ]] || fail "invalid LXC config filename: $file"
  vmids+=("$vmid")
done
(( ${#vmids[@]} > 0 )) || exit 0

mapfile -t sorted_ids < <(printf '%s\n' "${vmids[@]}" | LC_ALL=C sort -n)
for vmid in "${sorted_ids[@]}"; do
  file="/etc/pve/lxc/$vmid.conf"
  [[ -f "$file" ]] || fail "LXC configuration disappeared: $file"
  name="$(sed -n 's/^hostname:[[:space:]]*//p' "$file" | head -n 1)"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || fail "invalid hostname for LXC $vmid"

  state="$(pct status "$vmid")" || fail "could not read state of LXC $vmid"
  state="${state#status: }"
  [[ "$state" == running || "$state" == stopped ]] || fail "unsupported state for LXC $vmid: $state"

  # A guest may match several reasons; prefer template, stopped, excluded, disabled.
  if grep -Eq '^template:[[:space:]]*1([[:space:]]|$)' "$file"; then
    policy=template
  elif [[ "$state" == stopped ]]; then
    policy=stopped
  elif lxc_is_excluded "$vmid" "$name" "$exclusions"; then
    policy=excluded
  elif [[ "$update_running" == false ]]; then
    policy=running_lxc_disabled
  elif [[ "$scheduled_scope" == true ]] && ! lxc_is_scheduled "$vmid" "$scheduled_allowlist"; then
    policy=scheduled_not_authorized
  else
    policy=eligible
  fi
  printf '%s\t%s\t%s\t%s\n' "$vmid" "$name" "$state" "$policy"
done
