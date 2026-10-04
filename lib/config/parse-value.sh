#!/bin/bash
# Description: Parses one raw forge.conf value, trimming outer whitespace and removing matching outer quotes while rejecting unquoted whitespace.

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

[[ $# -eq 1 ]] || fail "usage: parse-value.sh RAW_VALUE"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
trim_script="$script_dir/../helpers/trim.sh"
[[ -r "$trim_script" ]] || fail "trim helper is not readable: $trim_script"

raw="$(bash "$trim_script" "$1")" || fail "could not trim configuration value"

if [[ "$raw" =~ ^\"([^\"]*)\"$ ]]; then
  printf '%s' "${BASH_REMATCH[1]}"
  exit 0
fi

if [[ "$raw" =~ ^\'([^\']*)\'$ ]]; then
  printf '%s' "${BASH_REMATCH[1]}"
  exit 0
fi

if [[ "$raw" =~ [[:space:]] ]]; then
  exit 1
fi

printf '%s' "$raw"
