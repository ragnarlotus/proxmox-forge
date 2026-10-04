#!/bin/bash
# Description: Loads the versioned Forge defaults and optional local overrides into the shared CONFIG and SEEN associative arrays, handling syntax, duplicate keys, and value parsing only.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run it through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

config_load_fail() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

config_parse_value() {
  local raw="$1"
  local output_variable="$2"

  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"

  if [[ "$raw" =~ ^\"([^\"]*)\"$ ]]; then
    printf -v "$output_variable" '%s' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$raw" =~ ^\'([^\']*)\'$ ]]; then
    printf -v "$output_variable" '%s' "${BASH_REMATCH[1]}"
    return 0
  fi

  [[ "$raw" =~ [[:space:]] ]] && return 1

  printf -v "$output_variable" '%s' "$raw"
}

config_load_file() {
  local config_file="$1"
  local allow_override="$2"
  local line line_number=0 key raw_value value
  local -A file_seen=()

  [[ -r "$config_file" ]] || {
    config_load_fail "configuration file is not readable: $config_file"
    return 1
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number += 1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

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

    config_parse_value "$raw_value" value || {
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
