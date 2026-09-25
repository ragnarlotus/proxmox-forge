#!/bin/bash
# Description: Prints Forge command-line usage and the currently available commands without implementing update logic.

set -u

cat <<'EOF'
Usage: forge COMMAND [ARGUMENTS]

Commands:
  validate-config             Load and validate the complete Forge configuration.
  check-host-requirements     Check whether the local Proxmox VE host satisfies current update requirements.
  update-host                 Update the local Proxmox VE host without guest-style rollback.
  resolve-target TARGET       Resolve one local LXC by exact VMID or exact name.
  list-lxc-targets            List LXC targets enabled by the current Forge scope.
  inspect-target TARGET       Read the complete available information for one running LXC.
  check-requirements TARGET   Check whether one LXC satisfies current update requirements.
  update TARGET               Update one local LXC through the protected Forge workflow.
  update-all                  Update all effective local LXC targets serially.
  help                        Show this help.
EOF
