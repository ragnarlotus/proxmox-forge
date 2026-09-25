#!/bin/bash
# Description: Appends one structured timestamped event to an existing Forge log without changing the caller's operation result.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 3 ]] || fail "usage: write.sh LOG_FILE LEVEL EVENT [FIELD ...]"
log_file="$1"
level="$2"
event="$3"
shift 3

[[ -f "$log_file" ]] || fail "log file does not exist: $log_file"
[[ -w "$log_file" ]] || fail "log file is not writable: $log_file"

case "$level" in
  INFO|WARN|ERROR)
    ;;
  *)
    fail "invalid log level '$level'"
    ;;
esac

[[ "$event" =~ ^[a-z][a-z0-9_-]*$ ]] || fail "invalid log event '$event'"

timestamp="$(date --iso-8601=seconds)" || fail "could not create log timestamp"

{
  printf '%s level=%s event=%s' "$timestamp" "$level" "$event"
  for field in "$@"; do
    printf ' %q' "$field"
  done
  printf '\n'
} >> "$log_file" || fail "could not append to log file: $log_file"
