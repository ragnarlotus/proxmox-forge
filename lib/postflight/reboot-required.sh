#!/bin/bash
# Description: Reports reboot indicators read-only; never reboots the host or guests.

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

[[ $# -eq 1 ]] || fail "usage: reboot-required.sh host|VMID"
target="$1"

if [[ "$target" == host ]]; then
  marker=no
  [[ -e /run/reboot-required ]] && marker=yes

  command -v uname >/dev/null 2>&1 || fail "uname is not available"
  command -v dpkg >/dev/null 2>&1 || fail "dpkg is not available"

  running_kernel="$(uname -r)" || fail "could not determine running host kernel"
  [[ -n "$running_kernel" ]] || fail "running host kernel is empty"

  latest_kernel=""
  shopt -s nullglob
  kernel_files=(/boot/vmlinuz-*-pve)
  shopt -u nullglob

  for file in "${kernel_files[@]}"; do
    [[ -f "$file" ]] || continue
    version="${file##*/vmlinuz-}"
    if [[ -z "$latest_kernel" ]] || dpkg --compare-versions "$version" gt "$latest_kernel"; then
      latest_kernel="$version"
    fi
  done

  kernel_update=unknown
  if [[ -n "$latest_kernel" ]]; then
    kernel_update=no
    if dpkg --compare-versions "$latest_kernel" gt "$running_kernel"; then
      kernel_update=yes
    fi
  fi

  reboot_required=unknown
  if [[ "$marker" == yes || "$kernel_update" == yes ]]; then
    reboot_required=yes
  elif [[ "$kernel_update" == no ]]; then
    reboot_required=no
  fi

  printf 'reboot_required=%s type=host marker=%s kernel_update=%s running_kernel=%s latest_installed_kernel=%s\n' \
    "$reboot_required" "$marker" "$kernel_update" "$running_kernel" "${latest_kernel:-unknown}"
  exit 0
fi

[[ "$target" =~ ^[0-9]+$ ]] || fail "expected host or numeric LXC VMID"
command -v pct >/dev/null 2>&1 || fail "pct is not available"

marker="$(
  pct exec "$target" -- sh -c '
    if [ -e /run/reboot-required ]; then
      printf yes
    else
      printf no
    fi
  ' </dev/null
)" || fail "could not check reboot indicator in LXC $target"

[[ "$marker" == yes || "$marker" == no ]] || fail "invalid reboot indicator response from LXC $target"
printf 'reboot_required=%s type=lxc vmid=%s marker=%s\n' "$marker" "$target" "$marker"
