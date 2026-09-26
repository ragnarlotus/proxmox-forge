#!/bin/bash
# Description: Appends one structured Forge event to its primary log and mirrors ERROR events to FORGE_ERROR_LOG when the caller configures a separate error log.

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
  INFO|WARN|ERROR) ;;
  *) fail "invalid log level '$level'" ;;
esac

[[ "$event" =~ ^[a-z][a-z0-9_-]*$ ]] || fail "invalid log event '$event'"

timestamp="$(date --iso-8601=seconds)" || fail "could not create log timestamp"
printf -v line '%s level=%s event=%s' "$timestamp" "$level" "$event"
for field in "$@"; do
  printf -v quoted '%q' "$field"
  line+=" $quoted"
done
line+=$'\n'

printf '%s' "$line" >> "$log_file" || fail "could not append to log file: $log_file"

if [[ "$level" == ERROR && -n "${FORGE_ERROR_LOG:-}" ]]; then
  [[ -f "$FORGE_ERROR_LOG" ]] || fail "error log file does not exist: $FORGE_ERROR_LOG"
  [[ -w "$FORGE_ERROR_LOG" ]] || fail "error log file is not writable: $FORGE_ERROR_LOG"
  printf '%s' "$line" >> "$FORGE_ERROR_LOG" || fail "could not append to error log: $FORGE_ERROR_LOG"
fi
