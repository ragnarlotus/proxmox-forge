#!/bin/bash
# Description: Initializes Forge logging under the local Proxmox FQDN, using rotated host logs, per-LXC logs and one retained log for each Forge update run.

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

[[ $# -eq 4 ]] || fail "usage: init.sh LOG_DIR LOG_KEEP SCOPE IDENTIFIER"
log_dir="$1"
log_keep="$2"
scope="$3"
identifier="$4"

[[ "$log_dir" == /* ]] || fail "LOG_DIR must be an absolute path"
[[ "$log_keep" =~ ^[1-9][0-9]*$ ]] || fail "LOG_KEEP must be a positive integer"
[[ "$scope" =~ ^[a-z][a-z0-9_-]*$ ]] || fail "invalid log scope '$scope'"
[[ "$identifier" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid log identifier '$identifier'"
command -v hostname >/dev/null 2>&1 || fail "hostname is not available"

pve_fqdn="$(hostname -f 2>/dev/null)" || fail "could not determine Proxmox host FQDN"
[[ "$pve_fqdn" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid Proxmox host FQDN '$pve_fqdn'"

umask 027
case "$scope" in
  host)
    [[ "$identifier" == "$pve_fqdn" ]] || \
      fail "host log identifier '$identifier' does not match local Proxmox FQDN '$pve_fqdn'"

    target_dir="$log_dir/$pve_fqdn/host"
    install -d -m 0750 "$target_dir" || fail "could not create host log directory: $target_dir"
    # Keep the current paths stable for host update and error mirroring.
    # Archive each previous host log when opening a new host update, retaining
    # LOG_KEEP files per stream (the active file plus older archives).
    stamp="$(date '+%Y%m%d_%H%M%S_%N')" || fail "could not create host log archive timestamp"
    for stream in common error; do
      active_log="$target_dir/$stream.log"
      archived_log="$target_dir/${stream}_${stamp}_$.log"
      if [[ -e "$active_log" || -L "$active_log" ]]; then
        [[ -f "$active_log" && ! -L "$active_log" ]] || \
          fail "host log is not a regular file: $active_log"
        [[ ! -e "$archived_log" && ! -L "$archived_log" ]] || \
          fail "host log archive already exists: $archived_log"
        mv -- "$active_log" "$archived_log" || fail "could not archive host log: $active_log"
      fi
      install -m 0640 /dev/null "$active_log" || fail "could not create host log: $active_log"

      mapfile -t logs < <(
        find "$target_dir" -maxdepth 1 -type f -name "${stream}_[0-9]*.log" -printf '%f\\n' | LC_ALL=C sort -r
      )
      for ((i = log_keep - 1; i < ${#logs[@]}; i++)); do
        rm -f -- "$target_dir/${logs[i]}" || fail "could not remove old host log: $target_dir/${logs[i]}"
      done
    done
    common_log="$target_dir/common.log"

    timestamp="$(date --iso-8601=seconds)" || fail "could not create log timestamp"
    printf '%s level=INFO event=log_open scope=host identifier=%s\n' \
      "$timestamp" "$identifier" >> "$common_log" || fail "could not initialize host common log"
    printf '%s\n' "$common_log"
    ;;
  lxc)
    [[ "$identifier" =~ ^[0-9]+$ ]] || fail "LXC log identifier must be a numeric VMID"
    target_dir="$log_dir/$pve_fqdn/lxc/$identifier"
    install -d -m 0750 "$target_dir" || fail "could not create LXC log directory: $target_dir"

    stamp="$(date '+%Y%m%d_%H%M%S_%N')" || fail "could not create log timestamp"
    log_file="$target_dir/${stamp}_$$.log"
    install -m 0640 /dev/null "$log_file" || fail "could not create log file: $log_file"

    timestamp="$(date --iso-8601=seconds)" || fail "could not create log timestamp"
    printf '%s level=INFO event=log_open scope=lxc identifier=%s\n' \
      "$timestamp" "$identifier" >> "$log_file" || fail "could not initialize LXC log file: $log_file"

    mapfile -t logs < <(
      find "$target_dir" -maxdepth 1 -type f -name '*.log' -printf '%f\n' | LC_ALL=C sort -r
    )

    for ((i = log_keep; i < ${#logs[@]}; i++)); do
      rm -f -- "$target_dir/${logs[i]}" || fail "could not remove old log: $target_dir/${logs[i]}"
    done

    printf '%s\n' "$log_file"
    ;;
  run)
    [[ "$identifier" == "${FORGE_RUN_ID:-}" ]] || fail "run log identifier does not match active Forge run"
    [[ "$identifier" =~ ^[0-9]{8}T[0-9]{6}-[0-9]+$ ]] || fail "invalid run log identifier"
    target_dir="$log_dir/$pve_fqdn/runs"
    install -d -m 0750 "$target_dir" || fail "could not create run log directory: $target_dir"
    log_file="$target_dir/$identifier.log"
    [[ ! -e "$log_file" ]] || fail "run log already exists: $log_file"
    install -m 0640 /dev/null "$log_file" || fail "could not create run log: $log_file"

    mapfile -t logs < <(
      find "$target_dir" -maxdepth 1 -type f -name '*.log' -printf '%f\n' | LC_ALL=C sort -r
    )
    for ((i = log_keep; i < ${#logs[@]}; i++)); do
      rm -f -- "$target_dir/${logs[i]}" || fail "could not remove old run log: $target_dir/${logs[i]}"
    done

    printf '%s\n' "$log_file"
    ;;
  *)
    fail "unsupported log scope '$scope'"
    ;;
esac
