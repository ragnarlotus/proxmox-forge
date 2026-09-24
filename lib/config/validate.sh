#!/bin/bash
# Description: Defines the forge.conf schema and validates loaded configuration keys, required values, booleans, paths, and numeric limits.

set -u

CONFIG_REQUIRED_KEYS=(
  UPDATE_HOST
  UPDATE_LXC
  UPDATE_VM
  UPDATE_EXTERNAL
  UPDATE_RUNNING_LXC
  UPDATE_STOPPED_LXC
  CONTINUE_AFTER_TARGET_FAILURE
  UPDATE_LXC_OS
  UPDATE_LXC_APPLICATION
  RUN_CUSTOM_SCRIPTS
  CUSTOM_SCRIPTS_DIR
  PREFLIGHT
  PROTECTION
  ROLLBACK_ON_FAILURE
  HEALTH_CHECK
  LOG_DIR
  LOG_KEEP
)

CONFIG_OPTIONAL_KEYS=(
  UPDATE_ONLY
  UPDATE_EXCLUDE
)

CONFIG_BOOLEAN_KEYS=(
  UPDATE_HOST
  UPDATE_LXC
  UPDATE_VM
  UPDATE_EXTERNAL
  UPDATE_RUNNING_LXC
  UPDATE_STOPPED_LXC
  CONTINUE_AFTER_TARGET_FAILURE
  UPDATE_LXC_OS
  UPDATE_LXC_APPLICATION
  RUN_CUSTOM_SCRIPTS
  PREFLIGHT
  PROTECTION
  ROLLBACK_ON_FAILURE
  HEALTH_CHECK
)

config_validate_fail() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

config_is_known_key() {
  local wanted="$1" key

  for key in "${CONFIG_REQUIRED_KEYS[@]}" "${CONFIG_OPTIONAL_KEYS[@]}"; do
    [[ "$key" == "$wanted" ]] && return 0
  done

  return 1
}

config_validate_boolean() {
  local key="$1" value="${CONFIG[$1]}"

  case "$value" in
    true|false)
      return 0
      ;;
    *)
      config_validate_fail "$key must be true or false (got '$value')"
      return 1
      ;;
  esac
}

config_validate() {
  local key

  [[ -n "${CONFIG+x}" && -n "${SEEN+x}" ]] || {
    config_validate_fail "configuration has not been loaded"
    return 1
  }

  for key in "${!SEEN[@]}"; do
    config_is_known_key "$key" || {
      config_validate_fail "unknown configuration key '$key'"
      return 1
    }
  done

  for key in "${CONFIG_REQUIRED_KEYS[@]}"; do
    [[ -n "${SEEN[$key]+x}" ]] || {
      config_validate_fail "missing required configuration key '$key'"
      return 1
    }
  done

  for key in "${CONFIG_BOOLEAN_KEYS[@]}"; do
    config_validate_boolean "$key" || return 1
  done

  [[ "${CONFIG[CUSTOM_SCRIPTS_DIR]}" == /* ]] || {
    config_validate_fail "CUSTOM_SCRIPTS_DIR must be an absolute path"
    return 1
  }

  [[ "${CONFIG[LOG_DIR]}" == /* ]] || {
    config_validate_fail "LOG_DIR must be an absolute path"
    return 1
  }

  [[ "${CONFIG[LOG_KEEP]}" =~ ^[1-9][0-9]*$ ]] || {
    config_validate_fail "LOG_KEEP must be a positive integer"
    return 1
  }
}
