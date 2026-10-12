#!/bin/bash
# Description: Lists the automatic local LXC update scope: currently running non-template containers when UPDATE_RUNNING_LXC is enabled.

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

[[ $# -eq 2 ]] || fail "usage: list-targets.sh UPDATE_RUNNING_LXC EXCLUDE"
update_running="$1"
exclusions="$2"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine LXC script directory"
exclude_helper="$script_dir/exclusions.sh"
[[ -r "$exclude_helper" ]] || fail "LXC exclusion helper is not readable: $exclude_helper"
# shellcheck source=/dev/null
source "$exclude_helper" || fail "could not load LXC exclusion helper"

case "$update_running" in
  true|false) ;;
  *) fail "UPDATE_RUNNING_LXC must be true or false" ;;
esac

[[ "$update_running" == true ]] || exit 0

run_id="${FORGE_RUN_ID:-}"
[[ -n "$run_id" ]] || fail "Forge run identifier is unavailable"
[[ "${FORGE_LXC_ENVIRONMENT_READY:-}" == "$run_id" ]] || \
  fail "LXC environment was not validated for this Forge run"

shopt -s nullglob
config_files=(/etc/pve/lxc/*.conf)
shopt -u nullglob

for config_file in "${config_files[@]}"; do
  vmid="${config_file##*/}"
  vmid="${vmid%.conf}"

  name="$(sed -n 's/^hostname:[[:space:]]*//p' "$config_file" | head -n 1)"
  [[ -n "$name" ]] || fail "LXC $vmid has no hostname in $config_file"

  state="$(pct status "$vmid")" || fail "could not read state for LXC $vmid"
  state="${state#status: }"
  case "$state" in
    running|stopped) ;;
    *) fail "LXC $vmid returned unsupported state '$state'" ;;
  esac

  if grep -Eq '^template:[[:space:]]*1([[:space:]]|$)' "$config_file"; then
    continue
  fi

  [[ "$state" == stopped ]] && continue
  lxc_is_excluded "$vmid" "$name" "$exclusions" && continue

  printf 'type=lxc vmid=%s name=%s state=running template=false\n' "$vmid" "$name"
done
