#!/bin/bash
# Description: Orchestrates forge.conf loading and validation, exposing the validated CONFIG associative array to callers that source this script.

set -u

config_get_fail() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

config_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || {
  config_get_fail "could not determine config script directory"
  return 1 2>/dev/null || exit 1
}

config_load_script="$config_script_dir/load.sh"
config_validate_script="$config_script_dir/validate.sh"

[[ -r "$config_load_script" ]] || {
  config_get_fail "config loader is not readable: $config_load_script"
  return 1 2>/dev/null || exit 1
}
[[ -r "$config_validate_script" ]] || {
  config_get_fail "config validator is not readable: $config_validate_script"
  return 1 2>/dev/null || exit 1
}

# shellcheck source=/dev/null
source "$config_load_script"
# shellcheck source=/dev/null
source "$config_validate_script"

config_get() {
  local config_file="$1"

  config_load "$config_file" || return 1
  config_validate || return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $# -eq 1 ]] || {
    printf 'ERROR: usage: get.sh CONFIG_FILE\n' >&2
    exit 1
  }

  config_get "$1" || exit 1

  for key in "${!CONFIG[@]}"; do
    printf '%s=%s\n' "$key" "${CONFIG[$key]}"
  done | sort
fi
