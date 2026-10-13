#!/bin/bash
# Description: Read-only dpkg package snapshots and durable APT upgrade counts.
# Source only from a guarded Forge update workflow.

FORGE_APT_DIR=""
FORGE_APT_ACTIVE=false
FORGE_APT_COUNT="-"
FORGE_APT_FINISHED=false

forge_apt_snapshot() (
  set -o pipefail
  local target="$1"
  local format='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n'
  if [[ "$target" == host ]]; then
    dpkg-query -W "-f=$format"
  elif [[ "$target" =~ ^[0-9]+$ ]]; then
    pct exec "$target" -- dpkg-query -W "-f=$format" </dev/null
  else
    return 2
  fi | awk -F '\t' 'NF == 3 && $3 ~ /^ii/ && $1 != "" && $2 != "" { print $1 "\t" $2 }'
)

forge_apt_delta() {
  local before="$1" after="$2" changed="$3" old new result count=0
  [[ -s "$before" && -s "$after" ]] || return 1
  command -v dpkg >/dev/null 2>&1 || return 1
  awk -F '\t' '
    FNR == NR { installed[$1]=$2; next }
    ($1 in installed) && installed[$1] != $2 {
      print installed[$1] "\t" $2
    }
  ' "$before" "$after" > "$changed" || return 1

  while IFS=$'\t' read -r old new; do
    [[ -n "$old" && -n "$new" ]] || return 1
    dpkg --compare-versions "$old" lt "$new"
    result=$?
    case "$result" in
      0) count=$((count + 1)) ;;
      1) ;; # A downgrade or unchanged version is not an upgrade.
      *) return 1 ;;
    esac
  done < "$changed"
  printf '%s\n' "$count"
}

forge_apt_begin() {
  local target="$1"
  FORGE_APT_COUNT="-"
  FORGE_APT_DIR="$(mktemp -d)" || {
    FORGE_APT_DIR=""
    return 1
  }
  if ! forge_apt_snapshot "$target" > "$FORGE_APT_DIR/before"; then
    forge_apt_cleanup
    return 1
  fi
  [[ -s "$FORGE_APT_DIR/before" ]] || {
    forge_apt_cleanup
    return 1
  }
}

forge_apt_finalize() {
  local target="$1" value
  [[ "$FORGE_APT_FINISHED" != true ]] || return 0
  FORGE_APT_FINISHED=true
  if [[ "$FORGE_APT_ACTIVE" == true && -n "$FORGE_APT_DIR" ]]; then
    if forge_apt_snapshot "$target" > "$FORGE_APT_DIR/after"; then
      value="$(forge_apt_delta "$FORGE_APT_DIR/before" "$FORGE_APT_DIR/after" "$FORGE_APT_DIR/changed")"
      if [[ "$value" =~ ^[0-9]+$ ]]; then
        FORGE_APT_COUNT="$value"
      fi
    fi
  fi
  forge_apt_cleanup
  # Only the bulk coordinator owns the final result_target line.
  # Transfer the measured fact to it without capturing/reformatting updater output.
  if [[ "${FORGE_RESULTS_AGGREGATE:-}" == bulk && -n "${FORGE_APT_RESULT_FILE:-}" ]]; then
    printf '%s\n' "$FORGE_APT_COUNT" > "$FORGE_APT_RESULT_FILE" ||
      printf 'WARNING: could not transfer APT count to bulk summary\n' >&2
  fi
}

forge_apt_cleanup() {
  if [[ -n "$FORGE_APT_DIR" ]]; then
    rm -rf -- "$FORGE_APT_DIR"
    FORGE_APT_DIR=""
  fi
}
