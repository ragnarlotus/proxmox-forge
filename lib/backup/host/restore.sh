#!/bin/bash
# Description: Provides a manual selective Proxmox host recovery utility for restoring important host configuration from a Forge archive, including use from a clean installation.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: %s BACKUP_FILE_OR_PATH [--single-node]\n' "$0" >&2
  printf 'Examples:\n' >&2
  printf '  %s bv-config-2026-09-26_03-00-02.tar.gz --single-node\n' "$0" >&2
  printf '  %s /mnt/backup/pve/bv-config-2026-09-26_03-00-02.tar.gz --single-node\n' "$0" >&2
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || usage
backup_file_input="$1"
single_node=false
if [[ $# -eq 2 ]]; then
  [[ "$2" == --single-node ]] || usage
  single_node=true
fi

[[ "$backup_file_input" == *.tar.gz ]] || fail "BACKUP_FILE_OR_PATH must end in .tar.gz"

for command_name in tar rsync install mktemp rm systemctl mount dirname; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is not available: $command_name"
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine host restore script directory"
backup_dir_lib="$(cd "$script_dir/.." && pwd)" || fail "could not determine backup library directory"
create_script="$script_dir/create.sh"
read_storage_script="$backup_dir_lib/read-storage.sh"
storage_path_script="$backup_dir_lib/storage-path.sh"

[[ -r "$create_script" ]] || fail "required host backup creator is not readable: $create_script"

if [[ "$backup_file_input" == /* ]]; then
  backup_file="$backup_file_input"
else
  [[ "$backup_file_input" != */* ]] || \
    fail "relative backup paths are not supported; use a file name or an absolute path"

  for helper in "$read_storage_script" "$storage_path_script"; do
    [[ -r "$helper" ]] || fail "required backup helper is not readable: $helper"
  done

  storage="$(bash "$read_storage_script")" || fail "could not determine host backup storage"
  storage_path="$(bash "$storage_path_script" "$storage")" || fail "could not determine host backup storage path"
  backup_file="$storage_path/pve/$backup_file_input"
fi

[[ -f "$backup_file" ]] || fail "host backup file not found: $backup_file"
tar -tzf "$backup_file" >/dev/null || fail "host backup archive is not readable: $backup_file"

if mount | grep -qE '^/dev/fuse on /etc/pve type fuse'; then
  printf 'restore_check=ok item=pmxcfs\n'
else
  printf 'WARNING: /etc/pve is not currently mounted through pmxcfs\n' >&2
fi

workspace="$(mktemp -d /root/proxmox-forge-host-restore.XXXXXX)" || fail "could not create restore workspace"
trap 'rm -rf -- "$workspace"' EXIT

tar -xzf "$backup_file" -C "$workspace" || fail "could not extract host backup into restore workspace"

safety_dir="/var/backups/proxmox-forge/host-safety"
safety_record="$(bash "$create_script" --directory "$safety_dir")" || \
  fail "could not create safety backup before host restore"
safety_backup="${safety_record##* path=}"
[[ "$safety_backup" != "$safety_record" && -s "$safety_backup" ]] || \
  fail "host safety backup did not return a valid recovery artifact"
printf 'restore_safety_backup=%s\n' "$safety_backup"

copy_file_if_exists() {
  local src="$1"
  local dst="$2"

  if [[ -f "$src" ]]; then
    printf 'restore_file=%s\n' "$dst"
    install -D -m 0644 "$src" "$dst" || fail "could not restore file: $dst"
  fi
}

copy_dir_if_exists() {
  local src="$1"
  local dst="$2"

  if [[ -d "$src" ]]; then
    printf 'restore_directory=%s\n' "$dst"
    mkdir -p "$dst" || fail "could not create restore directory: $dst"
    rsync -a "$src"/ "$dst"/ || fail "could not restore directory: $dst"
  fi
}

copy_dir_if_exists "$workspace/etc/pve/qemu-server" "/etc/pve/qemu-server"
copy_dir_if_exists "$workspace/etc/pve/lxc" "/etc/pve/lxc"
copy_file_if_exists "$workspace/etc/pve/storage.cfg" "/etc/pve/storage.cfg"
copy_file_if_exists "$workspace/etc/pve/datacenter.cfg" "/etc/pve/datacenter.cfg"

if [[ -f "$workspace/etc/network/interfaces" ]] \
  || [[ -f "$workspace/etc/hosts" ]] \
  || [[ -f "$workspace/etc/resolv.conf" ]]; then
  printf 'Network configuration exists in the backup. Restore it? (yes/no) [no]: '
  read -r net_confirm
  net_confirm="${net_confirm:-no}"

  if [[ "$net_confirm" == yes ]]; then
    copy_file_if_exists "$workspace/etc/network/interfaces" "/etc/network/interfaces"
    copy_file_if_exists "$workspace/etc/hosts" "/etc/hosts"
    copy_file_if_exists "$workspace/etc/resolv.conf" "/etc/resolv.conf"
  else
    printf 'restore_skipped=network\n'
  fi
fi

copy_dir_if_exists "$workspace/root/.ssh" "/root/.ssh"
copy_dir_if_exists "$workspace/usr/local/bin" "/usr/local/bin"

if [[ "$single_node" == true ]]; then
  cluster_db="$workspace/var/lib/pve-cluster/config.db"
  if [[ -f "$cluster_db" ]]; then
    install -D -m 0644 "$cluster_db" "/var/lib/pve-cluster/config.db" || \
      fail "could not restore single-node cluster database"
    systemctl restart pve-cluster || fail "cluster database restored but pve-cluster restart failed"
  else
    printf 'restore_skipped=cluster_db reason=missing_in_backup\n'
  fi
else
  printf 'restore_skipped=cluster_db reason=single_node_not_requested\n'
fi

printf 'restore=success type=host backup=%s safety_backup=%s\n' "$backup_file" "$safety_backup"
