#!/bin/bash
# Description: Exact ID/hostname exclusion predicate for automatic LXC selection.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run it through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

lxc_is_excluded() {
  local vmid="$1" hostname="$2" raw="$3" item
  local -a entries=()

  [[ -n "$raw" ]] || return 1

  IFS=',' read -r -a entries <<< "$raw"
  for item in "${entries[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    if [[ "$item" == "$vmid" || "$item" == "$hostname" ]]; then
      return 0
    fi
  done
  return 1
}
