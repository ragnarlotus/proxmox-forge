#!/bin/bash
# Description: Print one structured final-results record for a host or LXC.
# Source this helper from update orchestration; F225 will use these same facts.
forge_result_print() {
  [[ $# -ge 7 && $# -le 9 ]] || return 2
  local type="$1" vmid="$2" name="$3" selected="$4" attempted="$5" status="$6" reason="$7" exit_code="${8:-}" apt_upgraded="${9:--}"

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

  printf 'result_target type=%s vmid=%s name=%s selected=%s attempted=%s status=%s reason=%s' \
    "$type" "$vmid" "$name" "$selected" "$attempted" "$status" "$reason"
  if [[ -n "$exit_code" ]]; then
    printf ' exit_code=%s' "$exit_code"
  fi
  printf ' apt_upgraded=%s\n' "$apt_upgraded"
}
