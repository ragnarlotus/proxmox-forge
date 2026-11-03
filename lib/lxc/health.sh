#!/bin/bash
# Description: Performs the generic post-update health check for one LXC by confirming it remains running, accepts pct exec commands, and has no failed systemd services when systemd is present.

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

[[ $# -eq 1 ]] || fail "usage: health.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

command -v pct >/dev/null 2>&1 || fail "pct is not available"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine LXC script directory"
state_script="$script_dir/get-state.sh"
functional_script="$script_dir/health-scripts.sh"
config_get_script="$script_dir/../config/get.sh"
for helper in "$state_script" "$functional_script" "$config_get_script"; do
  [[ -r "$helper" ]] || fail "LXC health helper is not readable: $helper"
done

state="$(bash "$state_script" "$vmid")" || fail "could not read state for LXC $vmid"
[[ "$state" == running ]] || fail "LXC $vmid is $state after update"

init_system="$(
  pct exec "$vmid" -- sh -c '
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
      printf systemd
    else
      printf other
    fi
  ' </dev/null 200>&-
)"
init_result=$?

if (( init_result != 0 )); then
  printf 'ERROR: pct exec/init-system detection failed for LXC %s (exit code: %s)\n' \
    "$vmid" "$init_result" >&2
  exit "$init_result"
fi

systemd_services="not_applicable"

if [[ "$init_system" == systemd ]]; then
  failed_services="$(
    pct exec "$vmid" -- \
      systemctl --failed --type=service --no-legend --no-pager --plain \
      </dev/null 200>&- 2>&1
  )"
  systemctl_result=$?

  if (( systemctl_result != 0 )); then
    printf 'ERROR: could not query failed systemd services in LXC %s (exit code: %s)\n' \
      "$vmid" "$systemctl_result" >&2
    [[ -n "$failed_services" ]] && printf '%s\n' "$failed_services" >&2
    exit "$systemctl_result"
  fi

  if [[ -n "$failed_services" ]]; then
    printf 'ERROR: LXC %s has failed systemd services after update:\n%s\n' \
      "$vmid" "$failed_services" >&2
    exit 1
  fi

  systemd_services="clean"
fi

# The same health.sh is reused after rollback, so checks also validate the
# recovered application's behavior, not only its systemd state.
# shellcheck source=/dev/null
source "$config_get_script" || fail "could not load configuration helper"
config_get || fail "could not load effective Forge configuration"
bash "$functional_script" "$vmid" "${CONFIG[HEALTH_SCRIPTS_DIR]}"
result=$?
(( result == 0 )) || exit "$result"

printf 'health=ok vmid=%s state=running transport=pct_exec systemd_services=%s\n' \
  "$vmid" "$systemd_services"
