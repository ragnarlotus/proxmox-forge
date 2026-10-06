#!/bin/bash
# Description: Lists effective local running LXC update targets according to the configured LXC scope, always excluding templates and stopped containers.

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

[[ $# -eq 2 ]] || fail "usage: list-targets.sh UPDATE_LXC UPDATE_RUNNING_LXC"
update_lxc="$1"
update_running="$2"

for value in "$update_lxc" "$update_running"; do
  case "$value" in
    true|false) ;;
    *) fail "scope values must be true or false" ;;
  esac
done

[[ "$update_lxc" == true && "$update_running" == true ]] || exit 0

run_id="${FORGE_RUN_ID:-}"
[[ -n "$run_id" ]] || fail "Forge run identifier is unavailable"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
environment_script="$script_dir/get-environment.sh"
[[ -r "$environment_script" ]] || fail "LXC environment helper is not readable: $environment_script"

bash "$environment_script" >/dev/null || fail "LXC environment check failed"
export FORGE_LXC_ENVIRONMENT_READY="$run_id"

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

  printf 'type=lxc vmid=%s name=%s state=running template=false\n' "$vmid" "$name"
done
