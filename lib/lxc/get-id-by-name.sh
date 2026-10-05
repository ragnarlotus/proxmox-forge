#!/bin/bash
# Description: Resolves one exact LXC hostname to its VMID, failing when no exact match exists or when the name is ambiguous.

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

[[ $# -eq 1 ]] || fail "usage: get-id-by-name.sh NAME"
name="$1"
[[ -n "$name" ]] || fail "LXC name must not be empty"

run_id="${FORGE_RUN_ID:-}"
[[ -n "$run_id" ]] || fail "Forge run identifier is unavailable"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
environment_script="$script_dir/get-environment.sh"
[[ -r "$environment_script" ]] || fail "LXC environment helper is not readable: $environment_script"

if [[ "${FORGE_LXC_ENVIRONMENT_READY:-}" != "$run_id" ]]; then
  bash "$environment_script" >/dev/null || fail "LXC environment check failed"
  export FORGE_LXC_ENVIRONMENT_READY="$run_id"
fi

matches=()
shopt -s nullglob
for config_file in /etc/pve/lxc/*.conf; do
  candidate_name="$(sed -n 's/^hostname:[[:space:]]*//p' "$config_file" | head -n 1)"
  [[ "$candidate_name" == "$name" ]] || continue
  vmid="${config_file##*/}"
  matches+=("${vmid%.conf}")
done
shopt -u nullglob

case "${#matches[@]}" in
  0)
    fail "no LXC exists with exact name '$name'"
    ;;
  1)
    printf '%s' "${matches[0]}"
    ;;
  *)
    printf -v ids '%s, ' "${matches[@]}"
    ids="${ids%, }"
    fail "LXC name '$name' is ambiguous; exact matches: VMIDs $ids"
    ;;
esac
