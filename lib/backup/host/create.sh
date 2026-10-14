#!/bin/bash
# Description: Creates and validates one Proxmox host configuration backup in the pve directory of the backup storage selected by the node's enabled Proxmox backup jobs.

set -u -o pipefail

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run mutating operations through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: %s [--extra-paths PATH1,PATH2,...]\n' "$0" >&2
  exit 1
}

trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

extra_paths_value=""
extra_paths_seen=false

while (( $# )); do
  case "$1" in
    --extra-paths)
      [[ $# -ge 2 ]] || usage
      [[ "$extra_paths_seen" == false ]] || fail "--extra-paths may only be specified once"
      extra_paths_value="$2"
      extra_paths_seen=true
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

for command_name in hostname tar find install date rm mktemp python3; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is not available: $command_name"
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine host backup script directory"
backup_lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine backup library directory"
read_storage_script="$backup_lib_dir/read-storage.sh"
storage_path_script="$backup_lib_dir/storage-path.sh"
snapshot_db_script="$script_dir/snapshot-db.py"

for helper in "$read_storage_script" "$storage_path_script" "$snapshot_db_script"; do
  [[ -r "$helper" ]] || fail "required backup helper is not readable: $helper"
done

storage="$(bash "$read_storage_script")" || fail "could not determine host backup storage"
storage_path="$(bash "$storage_path_script" "$storage")" || fail "could not determine host backup storage path"
backup_dir="$storage_path/pve"

host="$(hostname -s)" || fail "could not determine local host name"
[[ -n "$host" ]] || fail "local host name is empty"
stamp="$(date '+%F_%H-%M-%S')" || fail "could not create backup timestamp"
backup_file="$backup_dir/${host}-config-${stamp}.tar.gz"
retention_days=14

include=(
  /etc/
  /root
  /var/lib/pve-cluster
  /usr/local/bin
  /opt/proxmox-forge/scripts.d/
  /opt/proxmox-forge/health.d/
)

# Host-local Forge overrides are optional, unlike the scripts directory.
if [[ -f /opt/proxmox-forge/forge.conf ]]; then
  include+=(/opt/proxmox-forge/forge.conf)
fi

if [[ -n "$extra_paths_value" ]]; then
  if [[ "$extra_paths_value" == ,* || "$extra_paths_value" == *, || "$extra_paths_value" == *,,* ]]; then
    fail "extra host backup paths contain an empty comma-separated entry"
  fi

  IFS=',' read -r -a extra_paths <<< "$extra_paths_value"

  for extra_path in "${extra_paths[@]}"; do
    extra_path="$(trim_value "$extra_path")"
    [[ -n "$extra_path" ]] || fail "extra host backup paths contain an empty entry"
    [[ "$extra_path" == /* ]] || fail "extra host backup path must be absolute: $extra_path"
    [[ -e "$extra_path" || -L "$extra_path" ]] || fail "configured extra host backup path does not exist: $extra_path"

    duplicate=false
    for existing_path in "${include[@]}"; do
      if [[ "${existing_path%/}" == "${extra_path%/}" ]]; then
        duplicate=true
        break
      fi
    done

    [[ "$duplicate" == true ]] || include+=("$extra_path")
  done
fi

umask 027
install -d -m 0750 "$backup_dir" || fail "could not create host backup directory: $backup_dir"

# config.db is a live SQLite database. Archiving its WAL/SHM files directly
# races with pmxcfs writes and can produce an inconsistent backup. Snapshot it
# through SQLite's online backup API without touching the running original.
snapshot_dir="$(mktemp -d)" || fail "could not create cluster database snapshot directory"
cleanup_snapshot() {
  rm -rf -- "$snapshot_dir"
}
trap cleanup_snapshot EXIT
install -d -m 0700 "$snapshot_dir/var/lib/pve-cluster" || fail "could not stage cluster database snapshot"
python3 "$snapshot_db_script" /var/lib/pve-cluster/config.db \
  "$snapshot_dir/var/lib/pve-cluster/config.db" || fail "could not snapshot live cluster database"

# Exclude only the original live SQLite files; append the validated standalone
# snapshot under the same member name expected by the host restore utility.
tar -czf "$backup_file" \
  --exclude=/var/lib/pve-cluster/config.db \
  --exclude=/var/lib/pve-cluster/config.db-wal \
  --exclude=/var/lib/pve-cluster/config.db-shm \
  --exclude=/var/lib/pve-cluster/config.db-journal \
  "${include[@]}" -C "$snapshot_dir" var/lib/pve-cluster/config.db
backup_result=$?
if (( backup_result != 0 )); then
  rm -f -- "$backup_file"
  fail "host configuration backup failed (tar exit code: $backup_result)"
fi

[[ -s "$backup_file" ]] || {
  rm -f -- "$backup_file"
  fail "host configuration backup is empty: $backup_file"
}

tar -tzf "$backup_file" >/dev/null
verify_result=$?
if (( verify_result != 0 )); then
  rm -f -- "$backup_file"
  fail "host configuration backup validation failed (tar exit code: $verify_result)"
fi

find "$backup_dir" -maxdepth 1 -type f \
  -name "${host}-config-*.tar.gz" -mtime "+$retention_days" -delete || \
  fail "could not apply host backup retention in $backup_dir"

printf 'backup=success type=host storage=%s path=%s\n' "$storage" "$backup_file"
