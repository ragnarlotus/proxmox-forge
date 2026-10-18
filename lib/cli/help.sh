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
  validate-config             Validate Forge configuration and running-LXC protection.
  show-config                 Print validated effective settings and their sources.
  status [--json]             Show the latest retained update-run result.
  history [RUN_ID] [--json]   List retained runs or show one run in detail.
  host update                 Update the local Proxmox VE host.
  lxc list-targets            List running LXCs selected by UPDATE_RUNNING_LXC.
  lxc update TARGET           Update one LXC; temporarily start it if stopped.
  lxc update all              Update LXCs from lxc list-targets; do not update host.
  update all                  Update the host first, then LXCs from lxc list-targets.
  update scheduled            Update only explicitly scheduled-authorized host/LXCs.
  help                        Show this help.
EOF
