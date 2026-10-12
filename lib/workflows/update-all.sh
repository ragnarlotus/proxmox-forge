#!/bin/bash
# Description: Coordinates full (host then LXC) or LXC-only update runs, selecting running guests before mutation and processing selected VMIDs serially.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run mutating operations through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: update-all.sh all|lxc"
mode="$1"
case "$mode" in
  all|lxc) ;;
  *) fail "unsupported update mode '$mode'" ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine workflow directory"
lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine lib directory"

config_get_script="$lib_dir/config/get.sh"
host_update_script="$lib_dir/host/update.sh"
lxc_list_targets_script="$lib_dir/lxc/list-targets.sh"
conflicts_script="$lib_dir/config/conflicts.sh"
root_space_script="$lib_dir/preflight/root-space.sh"
memory_script="$lib_dir/preflight/memory.sh"
lxc_update_script="$lib_dir/lxc/update.sh"
final_notification_script="$lib_dir/notifications/final.sh"

for helper in \
  "$config_get_script" \
  "$host_update_script" \
  "$lxc_list_targets_script" \
  "$conflicts_script" \
  "$root_space_script" \
  "$memory_script" \
  "$lxc_update_script" \
  "$final_notification_script"; do
  [[ -r "$helper" ]] || fail "required helper is not readable: $helper"
done

# shellcheck source=/dev/null
source "$config_get_script" || fail "could not load config helpers"
config_get || fail "could not load effective Forge configuration"

# Freeze only the effective LXC VMID scope before the first mutating operation. Each LXC is resolved again by update.sh when its turn begins so current state/template metadata are revalidated.
targets_output="$(
  bash "$lxc_list_targets_script" "${CONFIG[UPDATE_RUNNING_LXC]}" "${CONFIG[EXCLUDE]}"
)" || fail "could not resolve effective LXC target set"

vmids=()
while IFS= read -r target_record; do
  [[ -n "$target_record" ]] || continue

  vmid=""
  for field in $target_record; do
    if [[ "$field" == vmid=* ]]; then
      vmid="${field#*=}"
      break
    fi
  done

  [[ -n "$vmid" ]] || fail "target record returned no vmid: $target_record"
  [[ "$vmid" =~ ^[0-9]+$ ]] || fail "target record returned invalid vmid '$vmid'"

  vmids+=("$vmid")
done <<< "$targets_output"

# Verify all selected running LXCs before updating the host or any guest.
for vmid in "${vmids[@]}"; do
  bash "$root_space_script" "$vmid" "${CONFIG[MIN_ROOT_FREE_MB]}" || fail "LXC $vmid root space preflight failed; no updates started"
done

# Memory preflight for the frozen running LXC scope, before any mutations.
for vmid in "${vmids[@]}"; do
  bash "$memory_script" "$vmid" "${CONFIG[MIN_MEM_AVAILABLE_MB]}" || fail "LXC $vmid memory preflight failed; no updates started"
done

# All recovery conflicts must be resolved before the host or any LXC changes.
recovery_plan="$(bash "$conflicts_script" "${vmids[@]}")" || \
  fail "LXC protection conflicts detected; no updates started"

FORGE_LXC_BACKUP_ONLY_VMIDS=""
while IFS= read -r record; do
  [[ -n "$record" ]] || continue
  [[ "$record" == backup_fallback=* ]] || fail "invalid recovery plan: $record"
  vmid="${record#backup_fallback=}"
  [[ "$vmid" =~ ^[0-9]+$ ]] || fail "invalid recovery plan VMID"
  FORGE_LXC_BACKUP_ONLY_VMIDS+=" $vmid"
  printf 'INFO: LXC %s will use the existing vzdump backup for recovery\n' "$vmid"
done <<<"$recovery_plan"
export FORGE_LXC_BACKUP_ONLY_VMIDS

show_bulk_notification() {
  local status="$1" host_state="$2" succeeded_count="$3" failed_count="$4"
  shift 4
  printf '\nForge final notification preview (email not sent):\n'
  bash "$final_notification_script" bulk "$status" "$mode" "$host_state" \
    "$lxc_targets" "$succeeded_count" "$failed_count" "$@" || \
    printf 'WARNING: could not render final bulk notification\n' >&2
}

lxc_targets="${#vmids[@]}"
update_host=false
if [[ "$mode" == all && "${CONFIG[UPDATE_HOST]}" == true ]]; then
  update_host=true
fi

printf 'update_all=start mode=%s update_host=%s update_running_lxc=%s lxc_targets=%s\n' \
  "$mode" "$update_host" "${CONFIG[UPDATE_RUNNING_LXC]}" "$lxc_targets"

if [[ "$update_host" == true ]]; then
  printf 'update_all_stage=start stage=host\n'
  FORGE_NOTIFICATION_AGGREGATE=bulk bash "$host_update_script"
  host_result=$?

  if (( host_result != 0 )); then
    printf 'update_all=failed stage=host exit_code=%s lxc_started=false\n' "$host_result"
    printf '\nForge update summary: host FAILED (exit code %s); LXC updates not started (%s selected).\n' \
      "$host_result" "$lxc_targets"
    show_bulk_notification failed failed 0 0
    exit "$host_result"
  fi

  printf 'update_all_stage=success stage=host exit_code=0\n'
elif [[ "$mode" == all ]]; then
  printf 'update_all_stage=skipped stage=host reason=disabled\n'
fi

if [[ "${CONFIG[UPDATE_RUNNING_LXC]}" == true ]]; then
  succeeded=0
  failed=0
  failed_targets=()
  failed_records=()

  printf 'update_all_stage=start stage=lxc targets=%s\n' "$lxc_targets"

  for vmid in "${vmids[@]}"; do
    printf 'update_all_target=start vmid=%s\n' "$vmid"

    FORGE_NOTIFICATION_AGGREGATE=bulk bash "$lxc_update_script" "$vmid" scope
    target_result=$?

    if (( target_result == 0 )); then
      succeeded=$((succeeded + 1))
      printf 'update_all_target=success vmid=%s exit_code=0\n' "$vmid"
    else
      failed=$((failed + 1))
      failed_targets+=("$vmid (exit code $target_result)")
      failed_records+=("$vmid:$target_result")
      printf 'update_all_target=failed vmid=%s exit_code=%s\n' "$vmid" "$target_result"
    fi
  done

  if (( failed != 0 )); then
    printf 'update_all_stage=failed stage=lxc total=%s succeeded=%s failed=%s exit_code=1\n' \
      "$lxc_targets" "$succeeded" "$failed"
    printf 'update_all=failed stage=lxc total=%s succeeded=%s failed=%s exit_code=1\n' \
      "$lxc_targets" "$succeeded" "$failed"
    printf '\nForge update summary: '
    if [[ "$mode" == all ]]; then
      if [[ "$update_host" == true ]]; then
        printf 'host SUCCESS; '
      else
        printf 'host skipped; '
      fi
    fi
    printf '%s LXCs selected, %s succeeded, %s failed; overall FAILED.\n' \
      "$lxc_targets" "$succeeded" "$failed"
    for failed_target in "${failed_targets[@]}"; do
      printf '  Failed LXC: %s\n' "$failed_target"
    done
    final_status=failed
    if (( succeeded > 0 )) || [[ "$update_host" == true ]]; then
      final_status=partial
    fi
    host_state=skipped
    [[ "$update_host" == true ]] && host_state=success
    show_bulk_notification "$final_status" "$host_state" "$succeeded" "$failed" "${failed_records[@]}"
    exit 1
  fi

  printf 'update_all_stage=success stage=lxc total=%s succeeded=%s failed=0 exit_code=0\n' \
    "$lxc_targets" "$succeeded"
else
  printf 'update_all_stage=skipped stage=lxc reason=running_lxc_disabled\n'
fi

printf 'update_all=success mode=%s update_host=%s update_running_lxc=%s lxc_targets=%s\n' \
  "$mode" "$update_host" "${CONFIG[UPDATE_RUNNING_LXC]}" "$lxc_targets"

printf '\nForge update summary: '
if [[ "$mode" == all ]]; then
  if [[ "$update_host" == true ]]; then
    printf 'host SUCCESS; '
  else
    printf 'host skipped; '
  fi
fi
if [[ "${CONFIG[UPDATE_RUNNING_LXC]}" == true ]]; then
  printf '%s LXCs selected, %s succeeded, 0 failed; overall SUCCESS.\n' \
    "$lxc_targets" "$succeeded"
else
  printf 'LXC updates skipped (disabled); overall SUCCESS.\n'
fi
host_state=skipped
[[ "$update_host" == true ]] && host_state=success
if [[ "${CONFIG[UPDATE_RUNNING_LXC]}" == true ]]; then
  show_bulk_notification success "$host_state" "$succeeded" 0
else
  show_bulk_notification success "$host_state" 0 0
fi
