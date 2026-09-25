#!/bin/bash
# Description: Removes old Forge log files for one scope/identifier while keeping the configured number of most recent runs.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 4 ]] || fail "usage: prune.sh LOG_DIR LOG_KEEP SCOPE IDENTIFIER"
log_dir="$1"
log_keep="$2"
scope="$3"
identifier="$4"

[[ "$log_dir" == /* ]] || fail "LOG_DIR must be an absolute path"
[[ "$log_keep" =~ ^[1-9][0-9]*$ ]] || fail "LOG_KEEP must be a positive integer"
[[ "$scope" =~ ^[a-z][a-z0-9_-]*$ ]] || fail "invalid log scope '$scope'"
[[ "$identifier" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid log identifier '$identifier'"

target_dir="$log_dir/$scope/$identifier"
[[ -d "$target_dir" ]] || exit 0

mapfile -t logs < <(
  find "$target_dir" -maxdepth 1 -type f -name '*.log' -printf '%f\n' | LC_ALL=C sort -r
)

for ((i = log_keep; i < ${#logs[@]}; i++)); do
  rm -f -- "$target_dir/${logs[i]}" || fail "could not remove old log: $target_dir/${logs[i]}"
done
