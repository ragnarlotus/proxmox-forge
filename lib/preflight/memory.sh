#!/bin/bash
# Description: Enforces minimum available memory before updates, querying running LXCs read-only when needed.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run it through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 2 || $# -eq 3 ]] || fail "usage: memory.sh host|VMID MIN_MEM_AVAILABLE_MB [MEM_AVAILABLE_KB]"
target="$1"
minimum_mb="$2"
[[ "$minimum_mb" =~ ^[1-9][0-9]*$ ]] || fail "invalid minimum available memory (MiB): '$minimum_mb'"
(( ${#minimum_mb} <= 7 && minimum_mb <= 1048576 )) || fail "minimum available memory exceeds 1048576 MiB"

if [[ $# -eq 3 ]]; then
  available_kb="$3"
else
  [[ "$target" =~ ^[0-9]+$ ]] || fail "a running LXC VMID is required to query available memory"
  available_kb="$(pct exec "$target" -- awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo </dev/null 200>&-)" || fail "could not inspect available memory of LXC $target"
fi

[[ "$available_kb" =~ ^[0-9]+$ ]] || fail "invalid available-memory value for $target: '$available_kb'"
available_kb="$((10#$available_kb))"
minimum_kb="$((minimum_mb * 1024))"

if (( available_kb < minimum_kb )); then
  fail "$target has insufficient available memory: ${available_kb} KiB available, ${minimum_kb} KiB required"
fi

printf 'memory=ok target=%s available_kb=%s minimum_mb=%s\n' "$target" "$available_kb" "$minimum_mb"
