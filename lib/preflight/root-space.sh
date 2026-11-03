#!/bin/bash
# Description: Enforces free root filesystem space, querying a running LXC read-only when no measurement is supplied.

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

[[ $# -eq 2 || $# -eq 3 ]] || fail "usage: root-space.sh host|VMID MIN_ROOT_FREE_MB [ROOT_FREE_KB]"
target="$1"
min_mb="$2"
[[ "$min_mb" =~ ^[1-9][0-9]*$ ]] || fail "invalid minimum root free space (MiB): '$min_mb'"
(( ${#min_mb} <= 7 && min_mb <= 1048576 )) || fail "minimum root free space exceeds 1048576 MiB"

if [[ $# -eq 3 ]]; then
  free_kb="$3"
else
  [[ "$target" =~ ^[0-9]+$ ]] || fail "a running LXC VMID is required to query free space"
  output="$(pct exec "$target" -- df -Pk / </dev/null 200>&-)" || fail "could not inspect root filesystem space of LXC $target"
  free_kb="$(awk 'NR == 2 { print $4; exit }' <<<"$output")"
fi

[[ "$free_kb" =~ ^[0-9]+$ ]] || fail "invalid root filesystem free-space value for $target: '$free_kb'"
free_kb="$((10#$free_kb))"
min_kb="$((min_mb * 1024))"

if (( free_kb < min_kb )); then
  fail "$target has insufficient free space on /: ${free_kb} KiB available, ${min_kb} KiB required"
fi

printf 'space=ok target=%s free_kb=%s minimum_mb=%s\n' "$target" "$free_kb" "$min_mb"
