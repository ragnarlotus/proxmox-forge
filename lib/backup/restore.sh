#!/bin/bash
# Description: Restores one exact LXC backup volume using the storage topology recorded in the backup, failing closed when a safe simple restore cannot preserve that topology.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 2 && $# -le 3 ]] || fail "usage: restore.sh VMID BACKUP_VOLUME [--dry-run]"
vmid="$1"
backup_volume="$2"

[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"
[[ "$backup_volume" == *:* ]] || fail "BACKUP_VOLUME must be a Proxmox volume ID"

dry_run=false
if [[ $# -eq 3 ]]; then
  [[ "$3" == --dry-run ]] || fail "unknown option '$3'"
  dry_run=true
fi

for command_name in pct pvesm perl; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is not available"
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine backup script directory"
list_script="$script_dir/list-volumes.sh"
[[ -r "$list_script" ]] || fail "backup volume helper is not readable: $list_script"

backup_storage="${backup_volume%%:*}"
[[ -n "$backup_storage" ]] || fail "could not determine backup storage from volume ID"

available_backups="$(bash "$list_script" "$backup_storage" "$vmid")" || \
  fail "could not list backups for LXC $vmid on storage $backup_storage"
printf '%s\n' "$available_backups" | grep -Fqx -- "$backup_volume" || \
  fail "backup volume does not exist for LXC $vmid: $backup_volume"

backup_config="$(pvesm extractconfig "$backup_volume" 2>&1)"
extract_result=$?
if (( extract_result != 0 )); then
  printf '%s\n' "$backup_config" >&2
  exit "$extract_result"
fi

root_storage="$(
  BACKUP_CONFIG="$backup_config" perl -e '
    use strict;
    use warnings;

    my $config = $ENV{BACKUP_CONFIG};
    my ($rootfs) = $config =~ /^rootfs:\s*(.+)$/m;
    die "backup configuration has no rootfs entry\n" unless defined $rootfs;

    my ($root_volume) = split /,/, $rootfs, 2;
    $root_volume =~ s/^volume=//;
    my ($root_storage) = $root_volume =~ /^([^:]+):/;
    die "backup rootfs is not storage-backed\n" unless defined $root_storage && length $root_storage;

    while ($config =~ /^mp\d+:\s*(.+)$/mg) {
      my $value = $1;
      my @parts = split /,/, $value;
      my $source = shift @parts;
      $source =~ s/^volume=//;

      # Bind and device mount points are external to vzdump data. Proxmox
      # simple restore re-adds their configuration without copying contents.
      next if $source =~ m{^/};

      my ($storage) = $source =~ /^([^:]+):/;
      die "unsupported mount-point source in backup configuration: $source\n"
        unless defined $storage && length $storage;

      my %options;
      for my $part (@parts) {
        my ($key, $value) = split /=/, $part, 2;
        $options{$key} = defined($value) ? $value : "";
      }

      die "storage-backed mount point is excluded from the backup; automatic restore would not preserve its data: $source\n"
        unless defined($options{backup}) && $options{backup} eq "1";

      die "storage-backed mount point uses storage $storage while rootfs uses $root_storage; safe simple restore requires one common storage\n"
        unless $storage eq $root_storage;
    }

    print $root_storage;
  '
)" || fail "backup topology is not safe for automatic simple restore"

pvesm status --storage "$root_storage" >/dev/null 2>&1 || \
  fail "restore storage is not currently available: $root_storage"

restore_help="$(pct help restore --verbose 2>&1)" || fail "could not read pct restore capabilities"
printf '%s\n' "$restore_help" | grep -q -- '--storage' || fail "installed pct restore does not expose --storage"
printf '%s\n' "$restore_help" | grep -q -- '--force' || fail "installed pct restore does not expose --force"

restore_command=(pct restore "$vmid" "$backup_volume" --storage "$root_storage" --force 1)

if [[ "$dry_run" == true ]]; then
  printf 'restore=planned vmid=%s backup=%s backup_storage=%s root_storage=%s\n' \
    "$vmid" "$backup_volume" "$backup_storage" "$root_storage"
  printf 'command='
  printf '%q ' "${restore_command[@]}"
  printf '\n'
  exit 0
fi

if [[ -f "/etc/pve/lxc/${vmid}.conf" ]]; then
  state_output="$(pct status "$vmid" 2>&1)"
  state_result=$?
  if (( state_result != 0 )); then
    printf '%s\n' "$state_output" >&2
    exit "$state_result"
  fi

  [[ "$state_output" == 'status: stopped' ]] || \
    fail "LXC $vmid must be stopped before automatic restore"
fi

"${restore_command[@]}"
restore_result=$?

if (( restore_result != 0 )); then
  printf 'ERROR: restore failed for LXC %s from %s (exit code: %s)\n' \
    "$vmid" "$backup_volume" "$restore_result" >&2
  exit "$restore_result"
fi

printf 'restore=success vmid=%s backup=%s root_storage=%s\n' \
  "$vmid" "$backup_volume" "$root_storage"
