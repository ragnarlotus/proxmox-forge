#!/bin/bash
# F234: temporarily raise explicit LXC cores/memory limits and restore exactly.
# Do not modify cpulimit, swap, CPU weight or other Proxmox settings.

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

[[ $# -ge 3 ]] || fail "usage: resources.sh apply|restore VMID STATE_FILE [CORES MEMORY_MB MIN_HOST_FREE_MB]"
action="$1"
vmid="$2"
state_file="$3"
[[ "$vmid" =~ ^[1-9][0-9]*$ ]] || fail "invalid VMID"
[[ -f "$state_file" && ! -L "$state_file" ]] || fail "resource state file must exist"
command -v pct >/dev/null 2>&1 || fail "pct is unavailable"

read_limits() {
  local data
  data="$(pct config "$vmid" --current 1)" || return 1
  current_cores="$(printf '%s\n' "$data" | sed -n 's/^cores:[[:space:]]*//p' | head -n 1)"
  current_memory="$(printf '%s\n' "$data" | sed -n 's/^memory:[[:space:]]*//p' | head -n 1)"
  [[ -z "$current_cores" || "$current_cores" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ -z "$current_memory" || "$current_memory" =~ ^[1-9][0-9]*$ ]] || return 1
}

case "$action" in
  apply)
    [[ $# -eq 6 ]] || fail "apply requires desired cores, memory and minimum host-free MB"
    requested_cores="$4"
    requested_memory="$5"
    min_host_free="$6"
    for value in "$requested_cores" "$requested_memory" "$min_host_free"; do
      [[ "$value" =~ ^(0|[1-9][0-9]*)$ && ${#value} -le 7 ]] ||
        fail "resource values must be nonnegative integers"
    done
    [[ "$requested_cores" -le 8192 && "$requested_memory" -le 1048576 && "$min_host_free" -ge 1 ]] ||
      fail "invalid requested resource range"
    [[ ! -s "$state_file" ]] || fail "temporary resource state already exists"
    read_limits || fail "cannot read original LXC $vmid resource configuration"

    set_cores=0
    set_memory=0
    if (( requested_cores > 0 )); then
      [[ -n "$current_cores" ]] || fail "LXC $vmid has no explicit cores limit; refusing to infer an original value"
      if (( requested_cores > current_cores )); then
        host_cores="$(getconf _NPROCESSORS_ONLN)" || fail "cannot read host CPU count"
        [[ "$host_cores" =~ ^[1-9][0-9]*$ ]] || fail "invalid host CPU count"
        (( requested_cores <= host_cores )) ||
          fail "LXC $vmid requested $requested_cores cores exceeds $host_cores host CPUs"
        set_cores="$requested_cores"
      fi
    fi
    if (( requested_memory > 0 )); then
      [[ -n "$current_memory" ]] || fail "LXC $vmid has no explicit memory limit; refusing to infer an original value"
      if (( requested_memory > current_memory )); then
        host_available_kb="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)" ||
          fail "cannot read host available memory"
        [[ "$host_available_kb" =~ ^[0-9]+$ ]] || fail "invalid host available memory"
        delta_mb=$((requested_memory - current_memory))
        (( host_available_kb >= (delta_mb + min_host_free) * 1024 )) ||
          fail "LXC $vmid needs an additional $delta_mb MiB; host available memory would fall below $min_host_free MiB"
        set_memory="$requested_memory"
      fi
    fi

    if (( set_cores == 0 && set_memory == 0 )); then
      printf 'resources=skipped vmid=%s reason=limits_already_sufficient\n' "$vmid"
      exit 0
    fi

    # Persist the original settings BEFORE pct set; partial failures can be reverted.
    printf '%s %s %s %s %s\n' "$vmid" "${current_cores:-0}" "${current_memory:-0}" "$set_cores" "$set_memory" > "$state_file" ||
      fail "cannot persist original LXC resource limits"
    options=()
    (( set_cores == 0 )) || options+=(--cores "$set_cores")
    (( set_memory == 0 )) || options+=(--memory "$set_memory")
    pct set "$vmid" "${options[@]}" || fail "cannot apply temporary resources to LXC $vmid"
    read_limits || fail "cannot verify temporary LXC resource limits"
    (( set_cores == 0 )) || [[ "$current_cores" == "$set_cores" ]] ||
      fail "CPU limit was not applied to LXC $vmid"
    (( set_memory == 0 )) || [[ "$current_memory" == "$set_memory" ]] ||
      fail "memory limit was not applied to LXC $vmid"
    printf 'resources=applied vmid=%s temporary_cores=%s temporary_memory_mb=%s\n' "$vmid" "$set_cores" "$set_memory"
    ;;
  restore)
    [[ $# -eq 3 ]] || fail "restore accepts only VMID and STATE_FILE"
    [[ -s "$state_file" ]] || exit 0
    read -r saved_vmid original_cores original_memory applied_cores applied_memory < "$state_file" ||
      fail "cannot read original resource limits"
    [[ "$saved_vmid" == "$vmid" ]] || fail "resource state belongs to another VMID"
    for value in "$original_cores" "$original_memory" "$applied_cores" "$applied_memory"; do
      [[ "$value" =~ ^(0|[1-9][0-9]*)$ && ${#value} -le 7 ]] ||
        fail "invalid saved resource limits"
    done
    read_limits || fail "cannot inspect current resource limits before restoration"
    options=()
    if (( applied_cores > 0 )); then
      [[ "$current_cores" == "$applied_cores" || "$current_cores" == "$original_cores" ]] ||
        fail "LXC $vmid CPU limit changed externally; refusing to overwrite it"
      [[ "$current_cores" == "$original_cores" ]] || options+=(--cores "$original_cores")
    fi
    if (( applied_memory > 0 )); then
      [[ "$current_memory" == "$applied_memory" || "$current_memory" == "$original_memory" ]] ||
        fail "LXC $vmid memory limit changed externally; refusing to overwrite it"
      [[ "$current_memory" == "$original_memory" ]] || options+=(--memory "$original_memory")
    fi
    if (( ${#options[@]} > 0 )); then
      pct set "$vmid" "${options[@]}" || fail "cannot restore original limits for LXC $vmid"
    fi
    read_limits || fail "cannot verify restored resource limits"
    (( applied_cores == 0 )) || [[ "$current_cores" == "$original_cores" ]] ||
      fail "LXC $vmid CPU limit was not restored"
    (( applied_memory == 0 )) || [[ "$current_memory" == "$original_memory" ]] ||
      fail "LXC $vmid memory limit was not restored"
    : > "$state_file" || fail "cannot clear restored resource state"
    printf 'resources=restored vmid=%s original_cores=%s original_memory_mb=%s\n' \
      "$vmid" "$original_cores" "$original_memory"
    ;;
  *)
    fail "unsupported resource operation '$action'"
    ;;
esac
