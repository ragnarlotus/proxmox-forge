#!/bin/bash
# Description: Creates and validates one Proxmox host configuration backup, using the node backup storage by default and allowing an explicit directory for restore-safety use.

set -u -o pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: %s [--dry-run] [--directory ABSOLUTE_PATH]\n' "$0" >&2
  exit 1
}

dry_run=false
explicit_directory=""
while (( $# > 0 )); do
  case "$1" in
    --dry-run)
      dry_run=true
      shift
      ;;
    --directory)
      [[ $# -ge 2 ]] || usage
      explicit_directory="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

if [[ -n "$explicit_directory" && "$explicit_directory" != /* ]]; then
  fail "--directory must be an absolute path"
fi

for command_name in hostname tar find install date rm; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is not available: $command_name"
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine host backup script directory"
backup_dir_lib="$(cd "$script_dir/.." && pwd)" || fail "could not determine backup library directory"
read_storage_script="$backup_dir_lib/read-storage.sh"
storage_path_script="$backup_dir_lib/storage-path.sh"

storage="manual"
apply_retention=false
if [[ -n "$explicit_directory" ]]; then
  backup_dir="$explicit_directory"
else
  for helper in "$read_storage_script" "$storage_path_script"; do
    [[ -r "$helper" ]] || fail "required backup helper is not readable: $helper"
  done

  storage="$(bash "$read_storage_script")" || fail "could not determine host backup storage"
  storage_path="$(bash "$storage_path_script" "$storage")" || fail "could not determine host backup storage path"
  backup_dir="$storage_path/pve"
  apply_retention=true
fi

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
)

if [[ "$dry_run" == true ]]; then
  printf 'backup=planned type=host storage=%s directory=%s path=%s\n' \
    "$storage" "$backup_dir" "$backup_file"
  exit 0
fi

umask 027
install -d -m 0750 "$backup_dir" || fail "could not create host backup directory: $backup_dir"

tar -czf "$backup_file" "${include[@]}"
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

if [[ "$apply_retention" == true ]]; then
  find "$backup_dir" -maxdepth 1 -type f \
    -name "${host}-config-*.tar.gz" -mtime "+$retention_days" -delete || \
    fail "could not apply host backup retention in $backup_dir"
fi

printf 'backup=success type=host storage=%s path=%s\n' "$storage" "$backup_file"
