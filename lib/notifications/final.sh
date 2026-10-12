#!/bin/bash
# Description: Render one reusable plain-text final update notification.
# The caller prints this draft today; a later mail transport can reuse it.

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


# Extract only explicitly marked errors from the failed stage in the exact
# update log, never from unrelated earlier stages or later rollback output.
show_diagnostic() {
  local stage="$1" logfile="$2" message=""
  [[ -n "$logfile" && "$logfile" != none ]] || return 0
  printf 'Log: %s\n' "$logfile"
  [[ -r "$logfile" && "$stage" =~ ^[a-z][a-z0-9_]*$ ]] || return 0
  message="$(LC_ALL=C awk -v wanted="$stage" '
    /event=stage_start / && index($0, "stage=" wanted) { inside=1; last=""; next }
    inside && /event=stage_end / && index($0, "stage=" wanted) { inside=0; next }
    inside && /(^|[[:space:]])(ERROR:|FATAL:)/ {
      if (tolower($0) ~ /(password|passwd|token|authorization|secret|api.?key)/) {
        last="[potentially sensitive error redacted; inspect log]"
      } else { last=substr($0, 1, 240) }
    }
    END { if (last != "") print last }
  ' "$logfile")" || return 0
  [[ -n "$message" ]] && printf 'Last error message: %s\n' "$message"
  return 0
}

read_failure_details() {
  local detail_file="$1" line
  detail_stage="" detail_log=""
  [[ -r "$detail_file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      stage=*) detail_stage="${line#stage=}" ;;
      log=*) detail_log="${line#log=}" ;;
    esac
  done < "$detail_file"
  [[ "$detail_stage" =~ ^[a-z][a-z0-9_]*$ && -n "$detail_log" ]]
}

[[ $# -ge 2 ]] || fail "usage: final.sh host|lxc|bulk STATUS ..."
scope="$1"
status="$2"
shift 2

case "$status" in
  success|failed|partial) ;;
  *) fail "invalid final notification status '$status'" ;;
esac

case "$scope" in
  preflight)
    [[ "$status" == failed && $# -eq 2 ]] || fail "usage: final.sh preflight failed MODE REASON"
    mode="$1"; reason="$2"
    [[ "$mode" == all || "$mode" == lxc ]] || fail "invalid update mode"
    [[ -n "$reason" ]] || fail "invalid failure reason"
    [[ "$reason" != *$'\n'* && "$reason" != *$'\r'* ]] || fail "invalid failure reason"
    printf 'Subject: [Proxmox Forge] FAILED - %s update\n' "$mode"
    if [[ "$mode" == all ]]; then
      printf 'Status: FAILED\nOperation: forge update all\n'
    else
      printf 'Status: FAILED\nOperation: forge lxc update all\n'
    fi
    printf 'Phase: preflight\nReason: %s\nNo updates started.\n' "$reason"
    ;;
  host)
    [[ $# -ge 4 && $# -le 5 ]] || fail "usage: final.sh host STATUS HOSTNAME STAGE EXIT_CODE REBOOT [LOG]"
    hostname="$1"; stage="$2"; exit_code="$3"; reboot="$4"
    [[ "$hostname" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail "invalid host"
    [[ "$stage" =~ ^[a-z_]+$ ]] || fail "invalid stage"
    [[ "$exit_code" =~ ^[0-9]+$ ]] || fail "invalid exit code"
    [[ "$reboot" == yes || "$reboot" == no || "$reboot" == unknown ]] || fail "invalid reboot state"
    [[ "$status" != partial ]] || fail "partial is not valid for a single host"

    printf 'Subject: [Proxmox Forge] %s - Host %s\n' "${status^^}" "$hostname"
    printf 'Status: %s\nOperation: forge host update\nTarget: %s\n' "${status^^}" "$hostname"
    if [[ "$status" == failed ]]; then
      printf 'Failed stage: %s\nExit code: %s\n' "$stage" "$exit_code"
      show_diagnostic "$stage" "${5:-}"
    else
      printf 'Host update: completed\nRestart required: %s\n' "$reboot"
    fi
    ;;
  lxc)
    [[ $# -ge 4 && $# -le 5 ]] || fail "usage: final.sh lxc STATUS VMID STAGE EXIT_CODE REBOOT [LOG]"
    vmid="$1"; stage="$2"; exit_code="$3"; reboot="$4"
    [[ "$vmid" =~ ^[0-9]+$ ]] || fail "invalid VMID"
    [[ "$stage" =~ ^[a-z_]+$ ]] || fail "invalid stage"
    [[ "$exit_code" =~ ^[0-9]+$ ]] || fail "invalid exit code"
    [[ "$reboot" == yes || "$reboot" == no || "$reboot" == unknown ]] || fail "invalid reboot state"
    [[ "$status" != partial ]] || fail "partial is not valid for a single LXC"

    printf 'Subject: [Proxmox Forge] %s - LXC %s\n' "${status^^}" "$vmid"
    printf 'Status: %s\nOperation: forge lxc update\nTarget: LXC %s\n' "${status^^}" "$vmid"
    if [[ "$status" == failed ]]; then
      printf 'Failed stage: %s\nExit code: %s\n' "$stage" "$exit_code"
      show_diagnostic "$stage" "${5:-}"
    else
      printf 'LXC update: completed\nRestart required: %s\n' "$reboot"
    fi
    ;;
  bulk)
    [[ $# -ge 5 ]] || fail "usage: final.sh bulk STATUS MODE HOST_STATUS TOTAL SUCCEEDED FAILED [VMID:EXIT ...]"
    mode="$1"; host_status="$2"; total="$3"; succeeded="$4"; failed="$5"
    shift 5

    [[ "$mode" == all || "$mode" == lxc ]] || fail "invalid update mode"
    [[ "$host_status" == success || "$host_status" == failed || "$host_status" == skipped ]] || fail "invalid host status"
    [[ "$total" =~ ^[0-9]+$ && "$succeeded" =~ ^[0-9]+$ && "$failed" =~ ^[0-9]+$ ]] || fail "invalid target counts"
    (( succeeded + failed <= total )) || fail "invalid target counts"
    (( $# == failed )) || fail "failed target count does not match details"

    for target in "$@"; do
      [[ "$target" =~ ^[0-9]+:[0-9]+$ ]] || fail "invalid failed LXC record"
    done

    printf 'Subject: [Proxmox Forge] %s - %s update\n' "${status^^}" "$mode"
    if [[ "$mode" == all ]]; then
      printf 'Status: %s\nOperation: forge update all\nHost: %s\n' "${status^^}" "${host_status^^}"
      if [[ "$host_status" == failed ]]; then
        printf 'Host exit code: %s\n' "${FORGE_NOTIFICATION_HOST_EXIT:-unknown}"
        if read_failure_details "${FORGE_NOTIFICATION_DETAIL_DIR:-/nonexistent}/host"; then
          printf 'Host failed stage: %s\n' "$detail_stage"
          show_diagnostic "$detail_stage" "$detail_log"
        fi
      fi
    else
      printf 'Status: %s\nOperation: forge lxc update all\n' "${status^^}"
    fi
    printf 'LXCs selected: %s\nLXCs succeeded: %s\nLXCs failed: %s\n' \
      "$total" "$succeeded" "$failed"
    for target in "$@"; do
      vmid="${target%%:*}"
      printf 'Failed LXC: %s (exit code %s)\n' "$vmid" "${target#*:}"
      if read_failure_details "${FORGE_NOTIFICATION_DETAIL_DIR:-/nonexistent}/lxc-$vmid"; then
        printf 'Failed stage: %s\n' "$detail_stage"
        show_diagnostic "$detail_stage" "$detail_log"
      fi
    done
    ;;
  *)
    fail "invalid notification scope '$scope'"
    ;;
esac
