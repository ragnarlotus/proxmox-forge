#!/bin/bash
# Description: Reports APT packages explicitly held with apt-mark on the host
# or inside a running LXC, without changing any package selection or status.

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
case "$target" in
  host)
    command -v apt-mark >/dev/null 2>&1 || fail "apt-mark is not available on the host"
    output="$(LC_ALL=C apt-mark showhold)"
    result=$?
    target_fields="type=host"
    label="Proxmox host"
    ;;
  *)
    [[ "$target" =~ ^[0-9]+$ ]] || fail "target must be host or numeric VMID"
    command -v pct >/dev/null 2>&1 || fail "pct is not available"
    output="$(pct exec "$target" -- env LC_ALL=C apt-mark showhold </dev/null)"
    result=$?
    target_fields="type=lxc vmid=$target"
    label="LXC $target"
    ;;
esac

if (( result != 0 )); then
  printf 'ERROR: could not inspect held APT packages for %s (exit code %s)\n' \
    "$label" "$result" >&2
  exit "$result"
fi

held=()
if [[ -n "$output" ]]; then
  while IFS= read -r package; do
    [[ -n "$package" ]] || continue
    # Debian binary names may have an architecture suffix, e.g. name:amd64.
    [[ "$package" =~ ^[a-z0-9][a-z0-9+.:~-]*$ ]] || \
      fail "unexpected package name returned by apt-mark for $label"
    held+=("$package")
  done < <(printf '%s\n' "$output" | LC_ALL=C sort -u)
fi

for package in "${held[@]}"; do
  printf 'held_package=%s %s\n' "$package" "$target_fields"
done

printf 'held_packages=%s %s\n' "${#held[@]}" "$target_fields"
if (( ${#held[@]} > 0 )); then
  printf 'NOTICE: %s has %s explicitly held APT package(s); Forge will not unhold them.\n' \
    "$label" "${#held[@]}"
fi
