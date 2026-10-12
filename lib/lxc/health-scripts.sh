#!/bin/bash
# Description: Run optional per-LXC functional health scripts inside the guest,
# in lexical order, stopping on the first failed or unreadable script.

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

[[ $# -eq 2 ]] || fail "usage: health-scripts.sh VMID HEALTH_SCRIPTS_DIR"
vmid="$1"
health_scripts_dir="$2"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"
[[ "$health_scripts_dir" == /* ]] || fail "HEALTH_SCRIPTS_DIR must be absolute"
command -v pct >/dev/null 2>&1 || fail "pct is not available"

target_dir="$health_scripts_dir/$vmid"
if [[ ! -e "$target_dir" ]]; then
  printf 'functional_health=skipped vmid=%s reason=no_target_directory\n' "$vmid"
  exit 0
fi
[[ -d "$target_dir" ]] || fail "functional health path is not a directory: $target_dir"
[[ -r "$target_dir" && -x "$target_dir" ]] || fail "functional health directory is inaccessible: $target_dir"

# Match lexical script order independently of host locale.
export LC_ALL=C
shopt -s nullglob
scripts=("$target_dir"/*.sh)
shopt -u nullglob

count=0
for script in "${scripts[@]}"; do
  # Ignore non-regular files and symbolic links, including backup files.
  [[ -f "$script" && ! -L "$script" ]] || continue
  [[ -r "$script" ]] || fail "functional health script is not readable: $script"

  script_name="${script##*/}"
  printf 'functional_health_script=start vmid=%s script=%s\n' "$vmid" "$script_name"

  pct exec "$vmid" -- bash -s -- < "$script"
  result=$?
  if (( result != 0 )); then
    printf 'ERROR: functional health script failed for LXC %s: %s (exit code: %s)\n' \
      "$vmid" "$script_name" "$result" >&2
    exit "$result"
  fi

  printf 'functional_health_script=success vmid=%s script=%s\n' "$vmid" "$script_name"
  count=$((count + 1))
done

if (( count == 0 )); then
  printf 'functional_health=skipped vmid=%s reason=no_scripts\n' "$vmid"
else
  printf 'functional_health=ok vmid=%s count=%s\n' "$vmid" "$count"
fi
