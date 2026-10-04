#!/bin/bash
# Description: Lists the backup volume IDs available for one VMID on one Proxmox storage in stable lexical order.

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

[[ $# -eq 2 ]] || fail "usage: list-volumes.sh STORAGE VMID"
storage="$1"
vmid="$2"

[[ -n "$storage" ]] || fail "storage must not be empty"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"
command -v pvesm >/dev/null 2>&1 || fail "pvesm is not available"

output="$(LC_ALL=C pvesm list "$storage" --vmid "$vmid" --content backup 2>&1)"
result=$?

if (( result != 0 )); then
  printf '%s\n' "$output" >&2
  exit "$result"
fi

while IFS= read -r line; do
  read -r volume _ <<<"$line"

  case "${volume:-}" in
    "$storage":*) printf '%s\n' "$volume" ;;
  esac
done <<<"$output" | LC_ALL=C sort -u
