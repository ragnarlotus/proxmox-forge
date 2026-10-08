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
  validate-config             Load and validate the complete Forge configuration.
  check-host-requirements     Check whether the local Proxmox VE host satisfies current update requirements.
  update-host                 Update the local Proxmox VE host without guest-style rollback.
  list-lxc-targets            List currently running LXCs included by the automatic Forge scope.
  inspect-target TARGET       Read the complete available information for one running LXC.
  check-requirements TARGET   Check whether one LXC satisfies current update requirements.
  update TARGET               Explicitly update one LXC; a stopped target is started temporarily and restored to stopped.
  update-all                  Update the local Proxmox host first, then all effective LXC targets serially.
  help                        Show this help.
EOF
