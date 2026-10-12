#!/bin/bash
# Description: Lists the automatic local LXC update scope: running non-template containers, plus stopped containers when UPDATE_STOPPED_LXC is enabled.

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

[[ $# -eq 1 ]] || fail "usage: list-targets.sh UPDATE_STOPPED_LXC"
update_stopped="$1"

case "$update_stopped" in
  true|false) ;;
  *) fail "UPDATE_STOPPED_LXC must be true or false" ;;
esac


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

  [[ "$state" == stopped && "$update_stopped" == false ]] && continue

  printf 'type=lxc vmid=%s name=%s state=%s template=false\n' "$vmid" "$name" "$state"
done
