#!/bin/bash
# Description: Extracts one named field from a space-separated LXC record formatted as key=value pairs.

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

[[ $# -eq 2 ]] || fail "usage: get-field.sh RECORD FIELD"
record="$1"
wanted="$2"
[[ -n "$wanted" ]] || fail "field name must not be empty"

for field in $record; do
  if [[ "$field" == "$wanted="* ]]; then
    printf '%s' "${field#*=}"
    exit 0
  fi
done

exit 1
