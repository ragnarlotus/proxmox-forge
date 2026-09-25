#!/bin/bash
# Description: Creates the single Forge log owned by one target update, writes its opening record, and applies per-target LOG_KEEP retention.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 4 ]] || fail "usage: init.sh LOG_DIR LOG_KEEP SCOPE IDENTIFIER"
log_dir="$1"
log_keep="$2"
scope="$3"
identifier="$4"

[[ "$log_dir" == /* ]] || fail "LOG_DIR must be an absolute path"
[[ "$log_keep" =~ ^[1-9][0-9]*$ ]] || fail "LOG_KEEP must be a positive integer"
[[ "$scope" =~ ^[a-z][a-z0-9_-]*$ ]] || fail "invalid log scope '$scope'"
[[ "$identifier" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid log identifier '$identifier'"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
prune_script="$script_dir/prune.sh"
[[ -r "$prune_script" ]] || fail "log prune helper is not readable: $prune_script"

umask 027
target_dir="$log_dir/$scope/$identifier"
install -d -m 0750 "$target_dir" || fail "could not create log directory: $target_dir"

stamp="$(date '+%Y%m%d_%H%M%S_%N')" || fail "could not create log timestamp"
log_file="$target_dir/${stamp}_$$.log"
install -m 0640 /dev/null "$log_file" || fail "could not create log file: $log_file"

timestamp="$(date --iso-8601=seconds)" || fail "could not create log timestamp"
printf '%s level=INFO event=log_open scope=%s identifier=%s\n' \
  "$timestamp" "$scope" "$identifier" >> "$log_file" || fail "could not initialize log file: $log_file"

bash "$prune_script" "$log_dir" "$log_keep" "$scope" "$identifier" || \
  fail "could not apply log retention for $scope/$identifier"

printf '%s\n' "$log_file"
