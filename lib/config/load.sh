#!/bin/bash
# Description: Loads the versioned Forge defaults and optional local overrides into the shared CONFIG and SEEN associative arrays, handling syntax, duplicate keys, and value parsing only.

set -u

config_load_fail() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

config_load_file() {
  local config_file="$1"
  local allow_override="$2"
  local line line_number=0 key raw_value value
  local script_dir parse_script trim_script
  local -A file_seen=()

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || {
    config_load_fail "could not determine config script directory"
    return 1
  }
  parse_script="$script_dir/parse-value.sh"
  trim_script="$script_dir/../helpers/trim.sh"

  [[ -r "$config_file" ]] || {
    config_load_fail "configuration file is not readable: $config_file"
    return 1
  }
  [[ -r "$parse_script" ]] || {
    config_load_fail "config value parser is not readable: $parse_script"
    return 1
  }
  [[ -r "$trim_script" ]] || {
    config_load_fail "trim helper is not readable: $trim_script"
    return 1
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number += 1))
    line="$(bash "$trim_script" "$line")" || {
      config_load_fail "could not trim configuration line $line_number"
      return 1
    }

    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

    if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      config_load_fail "invalid configuration syntax at $config_file:$line_number"
      return 1
    fi

    key="${BASH_REMATCH[1]}"
    raw_value="${BASH_REMATCH[2]}"

    if [[ -n "${file_seen[$key]+x}" ]]; then
      config_load_fail "duplicate configuration key '$key' at $config_file:$line_number"
      return 1
    fi

    if [[ "$allow_override" != true && -n "${SEEN[$key]+x}" ]]; then
      config_load_fail "duplicate configuration key '$key' at $config_file:$line_number"
      return 1
    fi

    value="$(bash "$parse_script" "$raw_value")" || {
      config_load_fail "invalid value for '$key' at $config_file:$line_number"
      return 1
    }

    CONFIG["$key"]="$value"
    SEEN["$key"]=1
    file_seen["$key"]=1
  done < "$config_file"
}

config_load() {
  local default_file="$1"
  local override_file="${2:-}"

  declare -gA CONFIG=()
  declare -gA SEEN=()

  config_load_file "$default_file" false || return 1

  if [[ -n "$override_file" && -e "$override_file" ]]; then
    [[ -f "$override_file" ]] || {
      config_load_fail "local configuration path is not a regular file: $override_file"
      return 1
    }
    config_load_file "$override_file" true || return 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $# -ge 1 && $# -le 2 ]] || {
    printf 'ERROR: usage: load.sh DEFAULT_CONFIG_FILE [LOCAL_OVERRIDE_FILE]\n' >&2
    exit 1
  }

  config_load "$@" || exit 1

  for key in "${!CONFIG[@]}"; do
    printf '%s=%s\n' "$key" "${CONFIG[$key]}"
  done | sort
fi
