#!/bin/bash
# Description: Print one structured final-results record for a host or LXC.
# Source this helper from update orchestration; F225 will use these same facts.
forge_result_print() {
  [[ $# -ge 7 && $# -le 15 ]] || return 2
  local type="$1" vmid="$2" name="$3" selected="$4" attempted="$5" status="$6" reason="$7" exit_code="${8:-}" apt_upgraded="${9:--}" app_before="${10:--}" app_after="${11:--}" app_repository="${12:--}" result_detail="${13:-}" failed_stage="${14:--}" recovery="${15:--}"

  [[ "$type" == host || "$type" == lxc ]] || return 2
  if [[ "$type" == host ]]; then
    [[ "$vmid" == HOST ]] || return 2
  else
    [[ "$vmid" =~ ^[0-9]+$ ]] || return 2
  fi
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 2
  [[ "$selected" == true || "$selected" == false ]] || return 2
  [[ "$attempted" == true || "$attempted" == false ]] || return 2
  [[ "$status" == OK || "$status" == ERROR || "$status" == SKIPPED || "$status" == NOT_RUN ]] || return 2
  [[ "$reason" =~ ^[a-z][a-z0-9_]*$ ]] || return 2
  [[ -z "$exit_code" || "$exit_code" =~ ^[0-9]+$ ]] || return 2
  [[ "$apt_upgraded" == "-" || "$apt_upgraded" =~ ^[0-9]+$ ]] || return 2
  [[ "$app_before" == "-" || "$app_before" =~ ^v?[0-9][A-Za-z0-9._+~:-]*$ ]] || return 2
  [[ "$app_after" == "-" || "$app_after" =~ ^v?[0-9][A-Za-z0-9._+~:-]*$ ]] || return 2
  [[ "$app_repository" == "-" || "$app_repository" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
  [[ "$failed_stage" == "-" || "$failed_stage" =~ ^[a-z][a-z0-9_-]*$ ]] || return 2
  [[ "$recovery" == "-" || "$recovery" == success || "$recovery" == disabled || "$recovery" == unavailable || "$recovery" =~ ^failed:[0-9]+$ ]] || return 2
  if [[ -z "$result_detail" ]]; then
    result_detail="$(forge_result_encode "$(forge_result_text "$status" "$reason" "$exit_code" "$failed_stage" "" "$recovery" "")")"
  fi
  [[ "$result_detail" =~ ^([A-Za-z0-9_.~-]|%[0-9A-F]{2})+$ ]] || return 2

  local record
  printf -v record 'result_target type=%s vmid=%s name=%s selected=%s attempted=%s status=%s reason=%s' \
    "$type" "$vmid" "$name" "$selected" "$attempted" "$status" "$reason"
  if [[ -n "$exit_code" ]]; then
    record+=" exit_code=$exit_code"
  fi
  local extra
  printf -v extra ' apt_upgraded=%s app_before=%s app_after=%s app_repository=%s failed_stage=%s recovery=%s result_detail=%s' \
    "$apt_upgraded" "$app_before" "$app_after" "$app_repository" "$failed_stage" "$recovery" "$result_detail"
  record+="$extra"
  FORGE_RESULT_LAST_RECORD="$record"
  printf '%s\n' "$record"
  if [[ -n "${FORGE_RUN_LOG:-}" ]]; then
    printf '%s\n' "$record" >> "$FORGE_RUN_LOG" || \
      printf 'WARNING: could not append result to Forge run log\n' >&2
  fi
}

# Only values safe for single-token result_target records pass unchanged.
# All other UTF-8 bytes are %-escaped for F225 to decode in the Result column.
forge_result_encode() {
  local LC_ALL=C value="$1" out="" c hex i
  for ((i=0; i<${#value}; i++)); do
    c="${value:i:1}"
    case "$c" in
      [a-zA-Z0-9_.~-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

# Quote only literal diagnostic output from the failed stage, not an inferred
# root cause, a recovery stage, or unrelated output. Keep a bounded selection:
# the first four and the last eight matching lines in their original order.
# The full sanitized stage output remains in the target/run logs.
forge_result_stage_error() {
  local log_file="$1" stage="$2"
  [[ -f "$log_file" && "$stage" =~ ^[a-z][a-z0-9_-]*$ ]] || return 0
  awk -v token="stage=$stage" '
    function explicit_error(text) {
      return text ~ /^[[:space:]]*(ERROR:|Error:|error:|FATAL:|Fatal:|fatal:|Failed:|failed:|Failed to |E:|Err:[0-9]+|npm (ERR!|error)|pnpm (ERR|error)|ERR_PNPM_|yarn (error|ERR!)|dpkg: error|curl: \([0-9]+\)|Traceback \(most recent call last\):|[[:alnum:]_]*(Error|Exception):|Exception in thread |Error response from daemon:|CMake Error|make: \*\*\*|gmake: \*\*\*|\[[Ee][Rr][Rr][Oo][Rr]\]|File "[^"]+", line [0-9]+)/
    }
    function save(text, slot) {
      if (length(text) > 500)
        text = substr(text, 1, 500) " [line truncated; see log]"
      ++found
      if (found <= 4) first[found] = text
      slot = (found - 1) % 8
      tail[slot] = text
    }
    / event=stage_start / {
      active = (index($0, " " token " ") > 0)
      if (active) {
        found = 0
        delete first
        delete tail
      }
      next
    }
    / event=stage_end / {
      if (active && index($0, " " token " ") > 0) active = 0
      next
    }
    active && explicit_error($0) { save($0) }
    END {
      if (!found) exit
      if (found <= 12) {
        if (found <= 8) {
          for (i = 1; i <= found; i++) print tail[(i - 1) % 8]
        } else {
          for (i = 1; i <= found - 8; i++) print first[i]
          for (i = found - 7; i <= found; i++) print tail[(i - 1) % 8]
        }
      } else {
        for (i = 1; i <= 4; i++) print first[i]
        printf "[%d diagnostic lines omitted; see log]\n", found - 12
        for (i = found - 7; i <= found; i++) print tail[(i - 1) % 8]
      }
    }
  ' "$log_file"
}

forge_result_text() {
  local status="$1" reason="$2" code="$3" stage="$4" error="$5" recovery="$6" warning="$7" msg
  case "$status" in
    OK) msg="OK" ;;
    SKIPPED)
      case "$reason" in
        template) msg="SKIPPED: container is a template" ;;
        stopped) msg="SKIPPED: container is stopped" ;;
        excluded) msg="SKIPPED: excluded by configuration" ;;
        running_lxc_disabled) msg="SKIPPED: running LXC updates disabled" ;;
        host_disabled) msg="SKIPPED: host updates disabled" ;;
        *) msg="SKIPPED: $reason" ;;
      esac ;;
    NOT_RUN)
      case "$reason" in
        preflight_blocked) msg="NOT RUN: preflight blocked the update" ;;
        host_update_failed) msg="NOT RUN: host update failed" ;;
        *) msg="NOT RUN: $reason" ;;
      esac ;;
    ERROR)
      [[ "$stage" != "-" ]] || stage=unknown
      msg="ERROR: $stage (exit $code)"
      if [[ -n "$error" ]]; then
        if [[ "$error" == *$'\n'* ]]; then
          msg+=$'\nFailed stage output:\n'"$error"
        else
          msg+=": $error"
        fi
      fi
      ;;
  esac
  # Put the independent recovery/warning after the original multiline excerpt.
  # Preserve the existing single-line format for older consumers.
  local separator="; "
  [[ "$msg" == *$'\n'* ]] && separator=$'\n'
  case "$recovery" in
    success) msg+="${separator}recovery succeeded" ;;
    disabled) msg+="${separator}recovery skipped (disabled)" ;;
    unavailable) msg+="${separator}recovery unavailable (no artifact)" ;;
    failed:*) msg+="${separator}recovery failed (exit ${recovery#failed:})" ;;
  esac
  [[ -z "$warning" ]] || msg+="${separator}WARNING: $warning"
  printf '%s' "$msg"
}

# Nested bulk updates write a private handoff, never a second result_target.
# The three columns contain no whitespace: encoded text, stage, recovery.
forge_result_publish() {
  [[ $# -ge 12 && $# -le 16 ]] || return 2
  local stage="${13:--}" error="${14:-}" recovery="${15:--}" warning="${16:-}" detail
  detail="$(forge_result_encode "$(forge_result_text "$6" "$7" "$8" "$stage" "$error" "$recovery" "$warning")")"
  if [[ "${FORGE_RESULTS_AGGREGATE:-}" == bulk ]]; then
    if [[ -n "${FORGE_RESULT_DETAIL_FILE:-}" ]]; then
      printf '%s\t%s\t%s\n' "$detail" "$stage" "$recovery" > "$FORGE_RESULT_DETAIL_FILE" ||
        printf 'WARNING: could not transfer result details to bulk coordinator\n' >&2
    fi
    return 0
  fi
  forge_result_print "${@:1:12}" "$detail" "$stage" "$recovery" || return $?
  if [[ "${FORGE_RESULT_TABLE:-}" == true ]]; then
    forge_result_render "$FORGE_RESULT_LAST_RECORD"
  fi
  return 0
}

# The table consumes exactly the same validated records already printed.
# Reporting cannot mask the primary update's failure code.
forge_result_render() {
  local renderer
  renderer="$(dirname "${BASH_SOURCE[0]}")/table.py"
  if [[ ! -r "$renderer" ]] || ! command -v python3 >/dev/null 2>&1; then
    printf 'WARNING: final table unavailable (Python renderer missing)\n' >&2
    return 0
  fi
  if ! printf '%s\n' "$@" | python3 "$renderer"; then
    printf 'WARNING: final table rendering failed; structured results remain authoritative\n' >&2
    return 0
  fi

  # Mail is a best-effort optional presentation of these *same* final rows,
  # never a second update or collector. Nested bulk target runs never reach
  # this point, so one Forge execution produces at most one notification.
  if [[ "${CONFIG[EMAIL_NOTIFICATIONS]:-false}" == true ]]; then
    local notifier
    notifier="$(dirname "${BASH_SOURCE[0]}")/../notifications/send.py"
    if [[ ! -r "$notifier" ]]; then
      printf 'WARNING: Forge email notifier is unavailable\n' >&2
    elif ! printf '%s\n' "$@" | python3 "$notifier" "${CONFIG[NOTIFY_ONLY_ERRORS]:-true}"; then
      printf 'WARNING: Forge email notification was not accepted; update result unchanged\n' >&2
    fi
  fi
  return 0
}
