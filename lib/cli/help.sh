#!/bin/bash
# Description: Prints Forge command-line usage and the currently available commands without implementing update logic.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run it through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

cat <<'EOF'
Usage: forge COMMAND [ARGUMENTS]

Commands:
  validate-config             Validate the effective Forge configuration.
  host update                 Update the local Proxmox VE host.
  lxc list-targets            List running LXCs, plus stopped if UPDATE_STOPPED_LXC.
  lxc update TARGET           Update one LXC; temporarily start it if stopped.
  lxc update all              Update LXCs from lxc list-targets; do not update host.
  update all                  Update the host first, then LXCs from lxc list-targets.
  help                        Show this help.
EOF
