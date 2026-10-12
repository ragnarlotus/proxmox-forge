#!/bin/bash
# Description: Reports only explicitly held APT packages with a newer
# candidate version, using current APT package lists; never changes state.

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

[[ $# -eq 1 ]] || fail "usage: held-packages.sh host|VMID"
target="$1"
[[ "$target" == host || "$target" =~ ^[0-9]+$ ]] || fail "target must be host or numeric VMID"

# Run the same read-only inspection locally or in the guest. Do not infer
# application dependencies from an APT hold; these are package-level findings.
probe="$(cat <<'PROBE'
set -u
export LC_ALL=C
command -v apt-mark >/dev/null 2>&1 || exit 10
command -v apt-cache >/dev/null 2>&1 || exit 10
command -v dpkg >/dev/null 2>&1 || exit 10

target="$1"
if [[ "$target" == host ]]; then
  fields="type=host"
else
  fields="type=lxc vmid=$target"
fi

holds="$(apt-mark showhold)" || exit 11
[[ -n "$holds" ]] || exit 0

pending=0
while IFS= read -r package; do
  [[ -n "$package" ]] || continue
  [[ "$package" =~ ^[a-z0-9][a-z0-9+.:~-]*$ ]] || {
    printf 'ERROR: invalid held APT package name: %s\n' "$package" >&2
    exit 12
  }
  policy="$(apt-cache policy "$package")" || exit 13
  installed="$(awk '$1 == "Installed:" { print $2; found=1; exit } END { if (!found) exit 1 }' <<<"$policy")" || exit 14
  candidate="$(awk '$1 == "Candidate:" { print $2; found=1; exit } END { if (!found) exit 1 }' <<<"$policy")" || exit 14
  [[ "$installed" != "(none)" && "$candidate" != "(none)" ]] || continue

  if dpkg --compare-versions "$installed" lt "$candidate"; then
    printf 'held_upgrade_pending=%s installed=%s candidate=%s %s\n' \
      "$package" "$installed" "$candidate" "$fields"
    pending=$((pending + 1))
  else
    result=$?
    (( result == 1 )) || exit 15
  fi
done < <(printf '%s\n' "$holds" | LC_ALL=C sort -u)

if (( pending > 0 )); then
  printf 'held_upgrades_pending=%s %s\n' "$pending" "$fields"
  printf 'WARNING: %s explicitly held APT package(s) have newer candidate versions; those packages were not upgraded by the normal APT run.\n' "$pending"
fi
PROBE
)" || fail "could not prepare held-package inspection"

if [[ "$target" == host ]]; then
  bash -c "$probe" _ host
  result=$?
else
  command -v pct >/dev/null 2>&1 || fail "pct is not available"
  pct exec "$target" -- bash -c "$probe" _ "$target" </dev/null
  result=$?
fi

if (( result != 0 )); then
  printf 'ERROR: could not inspect pending held APT upgrades for %s (exit code %s)\n' \
    "$target" "$result" >&2
fi
exit "$result"
