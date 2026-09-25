#!/bin/bash
# Description: Prints Forge command-line usage and the currently available commands without implementing update logic.

set -u

cat <<'EOF'
Usage: forge COMMAND [ARGUMENTS]

Commands:
  validate-config             Load and validate the complete Forge configuration.
  resolve-target TARGET       Resolve one local LXC by exact VMID or exact name.
  list-lxc-targets            List LXC targets enabled by the current Forge scope.
  inspect-target TARGET       Read the complete available information for one running LXC.
  check-requirements TARGET   Check whether one LXC satisfies current update requirements.
  update TARGET               Update one local LXC through the protected Forge workflow.
  help                        Show this help.
EOF
