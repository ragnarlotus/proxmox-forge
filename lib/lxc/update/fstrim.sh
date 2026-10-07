#!/bin/bash
# Description: Runs the post-update filesystem trim for one LXC and preserves the real pct fstrim exit code; it does not perform logging or orchestration.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run mutating operations through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: fstrim.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

command -v pct >/dev/null 2>&1 || fail "pct is not available"

pct fstrim "$vmid"
result=$?

if (( result != 0 )); then
  printf 'ERROR: pct fstrim failed for LXC %s (exit code: %s)\n' \
    "$vmid" "$result" >&2
  exit "$result"
fi

printf 'fstrim=success vmid=%s\n' "$vmid"
