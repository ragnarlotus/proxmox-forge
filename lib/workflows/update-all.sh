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
  # Failures before a target log exists must still be diagnosable in F141.
  if [[ -n "${FORGE_RUN_LOG:-}" ]]; then
    printf -v run_error '%q' "$*"
    if ! printf '%s level=ERROR event=run_error message=%s\n' \
      "$(date --iso-8601=seconds)" "$run_error" >> "$FORGE_RUN_LOG"; then
      printf 'WARNING: could not record Forge run error: %s\n' "$FORGE_RUN_LOG" >&2
    fi
  fi
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
inventory_script="$lib_dir/results/inventory.sh"
result_record_script="$lib_dir/results/record.sh"

for helper in \
  "$config_get_script" \
  "$host_update_script" \
  "$lxc_list_targets_script" \
  "$conflicts_script" \
  "$root_space_script" \
  "$memory_script" \
  "$lxc_update_script" \
  "$inventory_script" \
  "$result_record_script"; do
  [[ -r "$helper" ]] || fail "required helper is not readable: $helper"
done

# shellcheck source=/dev/null
source "$config_get_script" || fail "could not load config helpers"
config_get || fail "could not load effective Forge configuration"

# F220: build a read-only inventory independently of the selected target scope.
# Neither selection nor mutation semantics may depend on the reporting model.
# shellcheck source=/dev/null
source "$result_record_script" || fail "could not load result record helper"

declare -a result_ids=()
declare -A result_name=() result_policy=() result_status=()
declare -A result_reason=() result_attempted=() result_exit=() result_apt=()
declare -A result_app_before=() result_app_after=() result_app_repository=()
declare -A result_detail=() result_failed_stage=() result_recovery=()
inventory_ready=false
inventory_output="$(bash "$inventory_script" "${CONFIG[UPDATE_RUNNING_LXC]}" "${CONFIG[EXCLUDE]}")" ||
  fail "could not read complete LXC inventory"

while IFS=$'\t' read -r id name state policy; do
  [[ -n "$id" ]] || continue
  [[ "$id" =~ ^[0-9]+$ && "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
    fail "invalid LXC inventory record"
  [[ -z "${result_name[$id]+x}" ]] || fail "duplicate LXC inventory VMID $id"
  [[ "$state" == running || "$state" == stopped ]] || fail "invalid state for LXC $id"
  case "$policy" in eligible|template|stopped|excluded|running_lxc_disabled) ;; *)
    fail "invalid LXC inventory policy for $id"
  esac
  result_ids+=("$id")
  result_name[$id]="$name"
  result_policy[$id]="$policy"
  result_attempted[$id]=false
  result_exit[$id]=""
  result_apt[$id]="-"
  result_app_before[$id]="-"
  result_app_after[$id]="-"
  result_app_repository[$id]="-"
  result_detail[$id]=""
  result_failed_stage[$id]="-"
  result_recovery[$id]="-"
  if [[ "$policy" == eligible ]]; then
    result_status[$id]=NOT_RUN
    result_reason[$id]=not_started
  else
    result_status[$id]=SKIPPED
    result_reason[$id]="$policy"
  fi
done <<< "$inventory_output"

host_name=""
host_status=SKIPPED
host_reason=host_disabled
host_selected=false
host_attempted=false
host_exit=""
host_apt="-"
host_detail=""
host_failed_stage="-"
host_recovery="-"
if [[ "$mode" == all ]]; then
  host_name="$(hostname -f)" || fail "could not read host FQDN for inventory"
  [[ "$host_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || fail "invalid host FQDN"
  if [[ "${CONFIG[UPDATE_HOST]}" == true ]]; then
    host_selected=true
    host_status=NOT_RUN
    host_reason=not_started
  fi
fi

# Private, disposable handoff for measured APT counts from nested updates.
# Missing reporting storage never changes which guests update or their exit code.
apt_result_dir="$(mktemp -d)" || {
  apt_result_dir=""
  printf 'WARNING: cannot create APT result handoff directory\n' >&2
}
result_not_run_reason=preflight_blocked
result_not_run_detail=""
inventory_ready=true
emit_final_inventory() {
  trap - EXIT
  local -a final_records=()
  [[ "$inventory_ready" == true ]] || return 0
  if [[ "$mode" == all ]]; then
    if [[ "$host_status" == NOT_RUN ]]; then host_reason="$result_not_run_reason"; fi
    if forge_result_print host HOST "$host_name" "$host_selected" "$host_attempted" \
      "$host_status" "$host_reason" "$host_exit" "$host_apt" "-" "-" "-" \
      "$host_detail" "$host_failed_stage" "$host_recovery"; then
      final_records+=("$FORGE_RESULT_LAST_RECORD")
    else
      printf 'ERROR: could not print host result record\n' >&2
    fi
  fi
  local id reason selected
  for id in "${result_ids[@]}"; do
    reason="${result_reason[$id]}"
    if [[ "${result_status[$id]}" == NOT_RUN ]]; then reason="$result_not_run_reason"; fi
    selected=false
    [[ "${result_policy[$id]}" == eligible ]] && selected=true
    local detail="${result_detail[$id]}"
    if [[ "${result_status[$id]}" == NOT_RUN && -n "$result_not_run_detail" ]]; then
      detail="$(forge_result_encode "NOT RUN: $result_not_run_detail")"
    fi
    if forge_result_print lxc "$id" "${result_name[$id]}" "$selected" \
      "${result_attempted[$id]}" "${result_status[$id]}" "$reason" "${result_exit[$id]}" "${result_apt[$id]}" \
      "${result_app_before[$id]}" "${result_app_after[$id]}" "${result_app_repository[$id]}" \
      "$detail" "${result_failed_stage[$id]}" "${result_recovery[$id]}"; then
      final_records+=("$FORGE_RESULT_LAST_RECORD")
    else
      printf 'ERROR: could not print result for LXC %s\n' "$id" >&2
    fi
  done
  forge_result_render "${final_records[@]}"
  if [[ -n "$apt_result_dir" ]]; then
    rm -rf -- "$apt_result_dir" ||
      printf 'WARNING: could not remove APT result handoff directory\n' >&2
  fi
  return 0
}
trap emit_final_inventory EXIT


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

  [[ "${result_policy[$vmid]:-}" == eligible ]] ||
    fail "selected LXC $vmid is absent or not eligible in the frozen inventory"
  vmids+=("$vmid")
done <<< "$targets_output"

# Assert reporting inventory agrees with effective selection before mutation.
declare -A selected_vmids=()
for vmid in "${vmids[@]}"; do
  [[ -z "${selected_vmids[$vmid]+x}" ]] || fail "duplicate selected VMID $vmid"
  selected_vmids[$vmid]=true
done
for vmid in "${result_ids[@]}"; do
  if [[ "${result_policy[$vmid]}" == eligible && -z "${selected_vmids[$vmid]+x}" ]]; then
    fail "eligible LXC $vmid missing from selected target set"
  fi
done

# Verify all selected running LXCs before updating the host or any guest.
for vmid in "${vmids[@]}"; do
  bash "$root_space_script" "$vmid" "${CONFIG[MIN_ROOT_FREE_MB]}" || {
    result_not_run_detail="LXC $vmid root space preflight failed"
    fail "LXC $vmid root space preflight failed; no updates started"
  }
done

# Memory preflight for the frozen running LXC scope, before any mutations.
for vmid in "${vmids[@]}"; do
  bash "$memory_script" "$vmid" "${CONFIG[MIN_MEM_AVAILABLE_MB]}" || {
    result_not_run_detail="LXC $vmid memory preflight failed"
    fail "LXC $vmid memory preflight failed; no updates started"
  }
done

# All recovery conflicts must be resolved before the host or any LXC changes.
recovery_plan="$(bash "$conflicts_script" "${vmids[@]}")" || {
  result_not_run_detail="LXC recovery protection conflicts detected"
  fail "LXC protection conflicts detected; no updates started"
}

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

lxc_targets="${#vmids[@]}"
host_failure_code=0
lxc_started=false
update_host=false
if [[ "$mode" == all && "${CONFIG[UPDATE_HOST]}" == true ]]; then
  update_host=true
fi

printf 'update_all=start mode=%s update_host=%s update_running_lxc=%s lxc_targets=%s\n' \
  "$mode" "$update_host" "${CONFIG[UPDATE_RUNNING_LXC]}" "$lxc_targets"

if [[ "$update_host" == true ]]; then
  printf 'update_all_stage=start stage=host\n'
  host_attempted=true
  FORGE_RESULTS_AGGREGATE=bulk FORGE_APT_RESULT_FILE="${apt_result_dir:+$apt_result_dir/host}" \
    FORGE_RESULT_DETAIL_FILE="${apt_result_dir:+$apt_result_dir/result-host}" \
    bash "$host_update_script"
  host_result=$?
  if [[ -n "$apt_result_dir" && -f "$apt_result_dir/host" ]]; then
    apt_value="$(< "$apt_result_dir/host")"
    [[ "$apt_value" =~ ^[0-9]+$ ]] && host_apt="$apt_value"
  fi

  if [[ -n "$apt_result_dir" && -f "$apt_result_dir/result-host" ]]; then
    IFS=$'\t' read -r detail stage recovery < "$apt_result_dir/result-host"
    if [[ "$detail" =~ ^([A-Za-z0-9_.~-]|%[0-9A-F]{2})+$ && \
          ( "$stage" == "-" || "$stage" =~ ^[a-z][a-z0-9_-]*$ ) && \
          ( "$recovery" == "-" || "$recovery" == success || "$recovery" == disabled || "$recovery" == unavailable || "$recovery" =~ ^failed:[0-9]+$ ) ]]; then
      host_detail="$detail"
      host_failed_stage="$stage"
      host_recovery="$recovery"
    fi
  fi

  if (( host_result != 0 )); then
    host_status=ERROR
    host_reason=update_failed
    host_exit="$host_result"
    host_failure_code="$host_result"
    # Host and LXC recovery points are independent. The already validated
    # guest scope must continue even when host backup/update fails.
    if [[ "${CONFIG[UPDATE_RUNNING_LXC]}" == true && "$lxc_targets" -gt 0 ]]; then
      printf 'update_all_stage=failed stage=host exit_code=%s continuing_with_lxc=true\n' \
        "$host_result"
      printf 'WARNING: host update failed (exit code %s); continuing with selected LXCs\n' \
        "$host_result" >&2
    else
      printf 'update_all_stage=failed stage=host exit_code=%s continuing_with_lxc=false\n' \
        "$host_result"
    fi
  else
    host_status=OK
    host_reason=completed
    printf 'update_all_stage=success stage=host exit_code=0\n'
  fi
elif [[ "$mode" == all ]]; then
  printf 'update_all_stage=skipped stage=host reason=disabled\n'
fi

succeeded=0
failed=0
if [[ "${CONFIG[UPDATE_RUNNING_LXC]}" == true ]]; then
  failed_targets=()

  printf 'update_all_stage=start stage=lxc targets=%s\n' "$lxc_targets"

  for vmid in "${vmids[@]}"; do
    printf 'update_all_target=start vmid=%s\n' "$vmid"

    lxc_started=true
    result_attempted[$vmid]=true
    FORGE_RESULTS_AGGREGATE=bulk FORGE_APT_RESULT_FILE="${apt_result_dir:+$apt_result_dir/lxc-$vmid}" \
      FORGE_APP_RESULT_FILE="${apt_result_dir:+$apt_result_dir/app-$vmid}" \
      FORGE_RESULT_DETAIL_FILE="${apt_result_dir:+$apt_result_dir/result-lxc-$vmid}" \
      bash "$lxc_update_script" "$vmid" scope
    target_result=$?
    if [[ -n "$apt_result_dir" && -f "$apt_result_dir/lxc-$vmid" ]]; then
      apt_value="$(< "$apt_result_dir/lxc-$vmid")"
      [[ "$apt_value" =~ ^[0-9]+$ ]] && result_apt[$vmid]="$apt_value"
    fi

    if [[ -n "$apt_result_dir" && -f "$apt_result_dir/app-$vmid" ]]; then
      IFS=$'\t' read -r app_before app_after app_repository < "$apt_result_dir/app-$vmid"
      if [[ "$app_before" == "-" || "$app_before" =~ ^v?[0-9][A-Za-z0-9._+~:-]*$ ]]; then
        if [[ "$app_after" == "-" || "$app_after" =~ ^v?[0-9][A-Za-z0-9._+~:-]*$ ]]; then
          result_app_before[$vmid]="$app_before"
          result_app_after[$vmid]="$app_after"
        fi
      fi
      if [[ "$app_repository" == "-" || "$app_repository" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        result_app_repository[$vmid]="$app_repository"
      fi
    fi

    if [[ -n "$apt_result_dir" && -f "$apt_result_dir/result-lxc-$vmid" ]]; then
      IFS=$'\t' read -r detail stage recovery < "$apt_result_dir/result-lxc-$vmid"
      if [[ "$detail" =~ ^([A-Za-z0-9_.~-]|%[0-9A-F]{2})+$ && \
            ( "$stage" == "-" || "$stage" =~ ^[a-z][a-z0-9_-]*$ ) && \
            ( "$recovery" == "-" || "$recovery" == success || "$recovery" == disabled || "$recovery" == unavailable || "$recovery" =~ ^failed:[0-9]+$ ) ]]; then
        result_detail[$vmid]="$detail"
        result_failed_stage[$vmid]="$stage"
        result_recovery[$vmid]="$recovery"
      fi
    fi

    if (( target_result == 0 )); then
      result_status[$vmid]=OK
      result_reason[$vmid]=completed
      succeeded=$((succeeded + 1))
      printf 'update_all_target=success vmid=%s exit_code=0\n' "$vmid"
    else
      result_status[$vmid]=ERROR
      result_reason[$vmid]=update_failed
      result_exit[$vmid]="$target_result"
      failed=$((failed + 1))
      failed_targets+=("$vmid (exit code $target_result)")
      printf 'update_all_target=failed vmid=%s exit_code=%s\n' "$vmid" "$target_result"
    fi
  done

  if (( failed != 0 )); then
    printf 'update_all_stage=failed stage=lxc total=%s succeeded=%s failed=%s exit_code=1\n' \
      "$lxc_targets" "$succeeded" "$failed"
    if (( host_failure_code != 0 )); then
      printf 'update_all=failed stage=host exit_code=%s lxc_started=%s lxc_succeeded=%s lxc_failed=%s\n' \
        "$host_failure_code" "$lxc_started" "$succeeded" "$failed"
      printf '\nForge update summary: host FAILED (exit code %s); ' "$host_failure_code"
      if (( succeeded > 0 )); then
        overall_status=PARTIAL
      else
        overall_status=FAILED
      fi
    else
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
      overall_status=FAILED
    fi
    printf '%s LXCs selected, %s succeeded, %s failed; overall %s.\n' \
      "$lxc_targets" "$succeeded" "$failed" "$overall_status"
    for failed_target in "${failed_targets[@]}"; do
      printf '  Failed LXC: %s\n' "$failed_target"
    done
    if (( host_failure_code != 0 )); then
      exit "$host_failure_code"
    fi
    exit 1
  fi

  printf 'update_all_stage=success stage=lxc total=%s succeeded=%s failed=0 exit_code=0\n' \
    "$lxc_targets" "$succeeded"
else
  printf 'update_all_stage=skipped stage=lxc reason=running_lxc_disabled\n'
fi

# A failed host always makes the combined CLI run fail, even if every
# selected guest updated successfully. Preserve the original host exit code.
if (( host_failure_code != 0 )); then
  printf 'update_all=failed stage=host exit_code=%s lxc_started=%s lxc_succeeded=%s lxc_failed=0\n' \
    "$host_failure_code" "$lxc_started" "$succeeded"
  if (( succeeded > 0 )); then
    overall_status=PARTIAL
  else
    overall_status=FAILED
  fi
  printf '\nForge update summary: host FAILED (exit code %s); ' "$host_failure_code"
  if [[ "${CONFIG[UPDATE_RUNNING_LXC]}" == true ]]; then
    printf '%s LXCs selected, %s succeeded, 0 failed; overall %s.\n' \
      "$lxc_targets" "$succeeded" "$overall_status"
  else
    printf 'LXC updates skipped (disabled); overall FAILED.\n'
  fi
  exit "$host_failure_code"
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
