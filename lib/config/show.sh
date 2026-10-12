#!/bin/bash
# Description: Prints validated effective Forge configuration with origin and safe quoting.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run it through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

config_show() {
  local key value
  local -a keys=()

  declare -p CONFIG >/dev/null 2>&1 || return 1
  declare -p CONFIG_SOURCES >/dev/null 2>&1 || return 1

  mapfile -t keys < <(printf '%s\n' "${!CONFIG[@]}" | LC_ALL=C sort)

  for key in "${keys[@]}"; do
    [[ -n "${CONFIG_SOURCES[$key]+x}" ]] || {
      printf 'ERROR: configuration source not known for %s\n' "$key" >&2
      return 1
    }

    case "$key" in
      *PASSWORD*|*PASSPHRASE*|*SECRET*|*TOKEN*|*CREDENTIAL*|*PRIVATE_KEY*|*API_KEY*)
        value="'<redacted>'"
        ;;
      *)
        printf -v value '%q' "${CONFIG[$key]}"
        ;;
    esac

    printf '%s=%s  # source=%s\n' "$key" "$value" "${CONFIG_SOURCES[$key]}"
  done
}
