#!/bin/bash
# Description: Executes one LXC's local Forge .sh custom scripts inside that container in lexical order; it does not perform logging or orchestration.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 2 ]] || fail "usage: custom-scripts.sh VMID CUSTOM_SCRIPTS_DIR"
vmid="$1"
custom_scripts_dir="$2"

[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"
[[ "$custom_scripts_dir" == /* ]] || fail "CUSTOM_SCRIPTS_DIR must be an absolute path"
command -v pct >/dev/null 2>&1 || fail "pct is not available"

target_dir="$custom_scripts_dir/$vmid"

if [[ ! -d "$target_dir" ]]; then
  printf 'custom_scripts=skipped vmid=%s reason=no_target_directory\n' "$vmid"
  exit 0
fi

mapfile -d '' -t scripts < <(
  find "$target_dir" -maxdepth 1 -type f -name '*.sh' -print0 | LC_ALL=C sort -z
)

if (( ${#scripts[@]} == 0 )); then
  printf 'custom_scripts=skipped vmid=%s reason=no_scripts\n' "$vmid"
  exit 0
fi

for script in "${scripts[@]}"; do
  script_name="${script##*/}"

  printf 'custom_script=start vmid=%s script=%s\n' "$vmid" "$script_name"

  pct exec "$vmid" -- bash -s -- < "$script"
  script_result=$?

  if (( script_result != 0 )); then
    printf 'ERROR: custom script failed for LXC %s: %s (exit code: %s)\n' \
      "$vmid" "$script_name" "$script_result" >&2
    exit "$script_result"
  fi

  printf 'custom_script=success vmid=%s script=%s\n' "$vmid" "$script_name"
done

printf 'custom_scripts=success vmid=%s count=%s\n' "$vmid" "${#scripts[@]}"
