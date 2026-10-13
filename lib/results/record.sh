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

  printf 'result_target type=%s vmid=%s name=%s selected=%s attempted=%s status=%s reason=%s' \
    "$type" "$vmid" "$name" "$selected" "$attempted" "$status" "$reason"
  if [[ -n "$exit_code" ]]; then
    printf ' exit_code=%s' "$exit_code"
  fi
  printf ' apt_upgraded=%s app_before=%s app_after=%s app_repository=%s failed_stage=%s recovery=%s result_detail=%s\n' \
    "$apt_upgraded" "$app_before" "$app_after" "$app_repository" "$failed_stage" "$recovery" "$result_detail"
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

# Only explicit diagnostic lines from the failed stage's sanitized log output.
# Do not infer causes from unrelated stages or recovery messages.
forge_result_stage_error() {
  local log_file="$1" stage="$2"
  [[ -f "$log_file" && "$stage" =~ ^[a-z][a-z0-9_-]*$ ]] || return 0
  awk -v token="stage=$stage" '
    / event=stage_start / {
      active = (index($0, " " token " ") > 0)
      if (active) message = ""
      next
    }
    / event=stage_end / {
      if (active && index($0, " " token " ") > 0) active = 0
      next
    }
    active && /^(ERROR|Error|FATAL|Fatal|fatal|E|Failed):[[:space:]]/ {
      message=$0
      sub(/^[^:]+:[[:space:]]*/, "", message)
    }
    END { if (message != "") print substr(message, 1, 240) }
  ' "$log_file" 2>/dev/null
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
      if [[ -n "$error" ]]; then msg+=": $error"; fi
      ;;
  esac
  case "$recovery" in
    success) msg+="; recovery succeeded" ;;
    disabled) msg+="; recovery skipped (disabled)" ;;
    unavailable) msg+="; recovery unavailable (no artifact)" ;;
    failed:*) msg+="; recovery failed (exit ${recovery#failed:})" ;;
  esac
  [[ -z "$warning" ]] || msg+="; WARNING: $warning"
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
  forge_result_print "${@:1:12}" "$detail" "$stage" "$recovery"
}
