#!/bin/bash
# Description: Prints Forge command-line usage and the currently available commands without implementing update logic.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run it through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

python3 "$(dirname "${BASH_SOURCE[0]}")/../i18n/help.py"
