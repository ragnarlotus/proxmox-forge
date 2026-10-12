#!/bin/bash
# Description: Defines the Forge configuration schema and validates the final merged default-plus-local configuration keys, required values, booleans, paths, and numeric limits.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run it through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

CONFIG_REQUIRED_KEYS=(
  UPDATE_HOST
  UPDATE_RUNNING_LXC
  UPDATE_LXC_OS
  UPDATE_LXC_APPLICATION
  RUN_CUSTOM_SCRIPTS
  CUSTOM_SCRIPTS_DIR
  CREATE_BACKUP_BEFORE_HOST_UPDATE
  HOST_BACKUP_EXTRA_PATHS
  CREATE_BACKUP_BEFORE_LXC_UPDATE
  BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE
  ROLLBACK_ON_FAILURE
  HEALTH_CHECK
  MIN_ROOT_FREE_MB
  MIN_MEM_AVAILABLE_MB
  LOG_DIR
  LOG_KEEP
)

CONFIG_BOOLEAN_KEYS=(
  UPDATE_HOST
  UPDATE_RUNNING_LXC
  UPDATE_LXC_OS
  UPDATE_LXC_APPLICATION
  RUN_CUSTOM_SCRIPTS
  CREATE_BACKUP_BEFORE_HOST_UPDATE
  CREATE_BACKUP_BEFORE_LXC_UPDATE
  BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE
  ROLLBACK_ON_FAILURE
  HEALTH_CHECK
)

config_validate_fail() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

config_is_known_key() {
  local wanted="$1" key

  for key in "${CONFIG_REQUIRED_KEYS[@]}"; do
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

config_trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

config_validate_host_backup_extra_paths() {
  local value="${CONFIG[HOST_BACKUP_EXTRA_PATHS]}"
  local path
  local -a paths=()

  [[ -z "$value" ]] && return 0

  if [[ "$value" == ,* || "$value" == *, || "$value" == *,,* ]]; then
    config_validate_fail "HOST_BACKUP_EXTRA_PATHS contains an empty comma-separated entry"
    return 1
  fi

  IFS=',' read -r -a paths <<< "$value"

  for path in "${paths[@]}"; do
    path="$(config_trim_value "$path")"
    [[ -n "$path" ]] || {
      config_validate_fail "HOST_BACKUP_EXTRA_PATHS contains an empty entry"
      return 1
    }
    [[ "$path" == /* ]] || {
      config_validate_fail "HOST_BACKUP_EXTRA_PATHS entries must be absolute paths (got '$path')"
      return 1
    }
  done
}

config_validate() {
  local key

  if ! declare -p CONFIG >/dev/null 2>&1 || ! declare -p SEEN >/dev/null 2>&1; then
    config_validate_fail "configuration has not been loaded"
    return 1
  fi

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

  config_validate_host_backup_extra_paths || return 1

  [[ "${CONFIG[LOG_DIR]}" == /* ]] || {
    config_validate_fail "LOG_DIR must be an absolute path"
    return 1
  }

  [[ "${CONFIG[MIN_ROOT_FREE_MB]}" =~ ^[1-9][0-9]*$ ]] || {
    config_validate_fail "MIN_ROOT_FREE_MB must be a positive integer (MiB)"
    return 1
  }
  (( ${#CONFIG[MIN_ROOT_FREE_MB]} <= 7 && CONFIG[MIN_ROOT_FREE_MB] <= 1048576 )) || {
    config_validate_fail "MIN_ROOT_FREE_MB must not exceed 1048576 MiB"
    return 1
  }

  [[ "${CONFIG[MIN_MEM_AVAILABLE_MB]}" =~ ^[1-9][0-9]*$ ]] || {
    config_validate_fail "MIN_MEM_AVAILABLE_MB must be a positive integer (MiB)"
    return 1
  }
  (( ${#CONFIG[MIN_MEM_AVAILABLE_MB]} <= 7 && CONFIG[MIN_MEM_AVAILABLE_MB] <= 1048576 )) || {
    config_validate_fail "MIN_MEM_AVAILABLE_MB must not exceed 1048576 MiB"
    return 1
  }

  [[ "${CONFIG[LOG_KEEP]}" =~ ^[1-9][0-9]*$ ]] || {
    config_validate_fail "LOG_KEEP must be a positive integer"
    return 1
  }
}
