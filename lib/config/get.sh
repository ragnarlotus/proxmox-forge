#!/bin/bash
# Description: Loads and validates Forge configuration from files for the owning CLI, or reconstructs the already-validated effective configuration from the active Forge run state.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run it through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

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

config_get_files() {
  local default_file="$1"
  local override_file="${2:-$(dirname "$default_file")/forge.conf}"

  config_load "$default_file" "$override_file" || return 1
  config_validate || return 1
}

config_get_runtime() {
  local line rest key value runtime_run_id="" config_count=0

  [[ -r "${FORGE_LOCK_FILE:-}" ]] || {
    config_get_fail "active Forge run state is not readable"
    return 1
  }

  declare -gA CONFIG=()
  declare -gA SEEN=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      $'meta\trun_id\t'*)
        runtime_run_id="${line#*$'\t'}"
        runtime_run_id="${runtime_run_id#*$'\t'}"
        ;;
      $'config\t'*)
        rest="${line#*$'\t'}"
        [[ "$rest" == *$'\t'* ]] || {
          config_get_fail "invalid configuration record in active Forge run state"
          return 1
        }
        key="${rest%%$'\t'*}"
        value="${rest#*$'\t'}"

        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || {
          config_get_fail "invalid configuration key in active Forge run state: '$key'"
          return 1
        }
        [[ -z "${SEEN[$key]+x}" ]] || {
          config_get_fail "duplicate configuration key in active Forge run state: '$key'"
          return 1
        }

        CONFIG["$key"]="$value"
        SEEN["$key"]=1
        config_count=$((config_count + 1))
        ;;
    esac
  done < "$FORGE_LOCK_FILE"

  [[ "$runtime_run_id" == "${FORGE_RUN_ID:-}" ]] || {
    config_get_fail "active Forge run state does not match this execution"
    return 1
  }
  (( config_count > 0 )) || {
    config_get_fail "active Forge run state contains no effective configuration"
    return 1
  }
}

config_get() {
  if [[ "${FORGE_RUNTIME_CONFIG_READY:-}" == true ]]; then
    config_get_runtime
  else
    config_get_files "$@"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $# -ge 1 && $# -le 2 ]] || {
    printf 'ERROR: usage: get.sh DEFAULT_CONFIG_FILE [LOCAL_OVERRIDE_FILE]\n' >&2
    exit 1
  }

  config_get "$@" || exit 1

  for key in "${!CONFIG[@]}"; do
    printf '%s=%s\n' "$key" "${CONFIG[$key]}"
  done | sort
fi
