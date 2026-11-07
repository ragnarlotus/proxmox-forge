#!/bin/bash
# Description: Defines the Forge configuration schema and validates the final merged default-plus-local configuration keys, required values, booleans, paths, and numeric limits.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run it through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

CONFIG_REQUIRED_KEYS=(
  LANGUAGE
  UPDATE_HOST
  CHECK_FORGE_UPDATES_BEFORE_UPDATE
  PERSISTENT_UPDATE_SESSION
  UPDATE_RUNNING_LXC
  SCHEDULED_UPDATE_HOST
  SCHEDULED_UPDATE_LXC
  EMAIL_NOTIFICATIONS
  NOTIFY_MANUAL
  NOTIFY_SCHEDULED
  EXCLUDE
  UPDATE_LXC_OS
  UPDATE_LXC_APPLICATION
  RUN_CUSTOM_SCRIPTS
  CUSTOM_SCRIPTS_DIR
  LXC_UPDATE_TEMP_CORES
  LXC_UPDATE_TEMP_MEMORY_MB
  CREATE_BACKUP_BEFORE_HOST_UPDATE
  HOST_BACKUP_EXTRA_PATHS
  CREATE_BACKUP_BEFORE_LXC_UPDATE
  ROLLBACK_ON_FAILURE
  HEALTH_CHECK
  HEALTH_SCRIPTS_DIR
  MIN_ROOT_FREE_MB
  MIN_MEM_AVAILABLE_MB
  LOG_DIR
  LOG_KEEP
)

CONFIG_BOOLEAN_KEYS=(
  UPDATE_HOST
  CHECK_FORGE_UPDATES_BEFORE_UPDATE
  PERSISTENT_UPDATE_SESSION
  UPDATE_RUNNING_LXC
  SCHEDULED_UPDATE_HOST
  EMAIL_NOTIFICATIONS
  UPDATE_LXC_OS
  UPDATE_LXC_APPLICATION
  RUN_CUSTOM_SCRIPTS
  CREATE_BACKUP_BEFORE_HOST_UPDATE
  CREATE_BACKUP_BEFORE_LXC_UPDATE
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

config_validate_exclude() {
  local value="${CONFIG[EXCLUDE]}" entry
  local -a entries=()

  [[ -z "$value" ]] && return 0

  if [[ "$value" == ,* || "$value" == *, || "$value" == *,,* ]]; then
    config_validate_fail "EXCLUDE contains an empty comma-separated entry"
    return 1
  fi

  IFS=',' read -r -a entries <<< "$value"
  for entry in "${entries[@]}"; do
    entry="$(config_trim_value "$entry")"
    [[ "$entry" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || {
      config_validate_fail "EXCLUDE contains an invalid VMID/name: '$entry'"
      return 1
    }
  done
}

# Schedule authorization must name exact, unique numeric VMIDs only.
# Unknown VMIDs are rejected by the scheduled workflow before any update.
config_validate_scheduled_lxc() {
  local value="${CONFIG[SCHEDULED_UPDATE_LXC]}" entry
  local -a entries=()
  local -A seen=()

  [[ -z "$value" ]] && return 0
  if [[ "$value" == ,* || "$value" == *, || "$value" == *,,* ]]; then
    config_validate_fail "SCHEDULED_UPDATE_LXC contains an empty comma-separated entry"
    return 1
  fi
  IFS=',' read -r -a entries <<< "$value"
  for entry in "${entries[@]}"; do
    entry="$(config_trim_value "$entry")"
    [[ "$entry" =~ ^[1-9][0-9]*$ && ${#entry} -le 9 ]] || {
      config_validate_fail "SCHEDULED_UPDATE_LXC requires numeric VMIDs without leading zeroes (got '$entry')"
      return 1
    }
    [[ -z "${seen[$entry]+x}" ]] || {
      config_validate_fail "SCHEDULED_UPDATE_LXC contains duplicate VMID '$entry'"
      return 1
    }
    seen["$entry"]=1
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

  case "${CONFIG[LANGUAGE]}" in
    en|es) ;;
    *) config_validate_fail "LANGUAGE must be en or es (got '${CONFIG[LANGUAGE]}')"; return 1 ;;
  esac

  for key in NOTIFY_MANUAL NOTIFY_SCHEDULED; do
    case "${CONFIG[$key]}" in
      none|errors|all) ;;
      *) config_validate_fail "$key must be none, errors or all (got '${CONFIG[$key]}')"; return 1 ;;
    esac
  done

  [[ "${CONFIG[CUSTOM_SCRIPTS_DIR]}" == /* ]] || {
    config_validate_fail "CUSTOM_SCRIPTS_DIR must be an absolute path"
    return 1
  }

  [[ "${CONFIG[HEALTH_SCRIPTS_DIR]}" == /* ]] || {
    config_validate_fail "HEALTH_SCRIPTS_DIR must be an absolute path"
    return 1
  }

  config_validate_host_backup_extra_paths || return 1
  config_validate_exclude || return 1
  config_validate_scheduled_lxc || return 1

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

  for key in LXC_UPDATE_TEMP_CORES LXC_UPDATE_TEMP_MEMORY_MB; do
    [[ "${CONFIG[$key]}" =~ ^(0|[1-9][0-9]*)$ ]] || {
      config_validate_fail "$key must be a nonnegative integer"
      return 1
    }
  done
  (( ${#CONFIG[LXC_UPDATE_TEMP_CORES]} <= 4 && CONFIG[LXC_UPDATE_TEMP_CORES] <= 8192 )) || {
    config_validate_fail "LXC_UPDATE_TEMP_CORES must not exceed 8192"
    return 1
  }
  (( ${#CONFIG[LXC_UPDATE_TEMP_MEMORY_MB]} <= 7 && CONFIG[LXC_UPDATE_TEMP_MEMORY_MB] <= 1048576 )) || {
    config_validate_fail "LXC_UPDATE_TEMP_MEMORY_MB must not exceed 1048576"
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
