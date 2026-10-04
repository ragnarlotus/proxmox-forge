#!/bin/bash
# Description: Restores one exact LXC backup volume with Proxmox advanced restore semantics, preserving excluded storage-backed mount points without restoring their data.

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
prepare_script="$script_dir/prepare-restore.sh"

for helper in "$list_script" "$prepare_script"; do
  [[ -r "$helper" ]] || fail "required backup helper is not readable: $helper"
done

backup_storage="${backup_volume%%:*}"
[[ -n "$backup_storage" ]] || fail "could not determine backup storage from volume ID"

available_backups="$(bash "$list_script" "$backup_storage" "$vmid")" || \
  fail "could not list backups for LXC $vmid on storage $backup_storage"
printf '%s\n' "$available_backups" | grep -Fqx -- "$backup_volume" || \
  fail "backup volume does not exist for LXC $vmid: $backup_volume"

plan_json="$(bash "$prepare_script" "$vmid" "$backup_volume")" || \
  fail "could not prepare safe restore for LXC $vmid"

mapfile -d '' -t fields < <(
  PLAN_JSON="$plan_json" perl -MJSON::PP -e '
    use strict;
    use warnings;

    my $plan = decode_json($ENV{PLAN_JSON});
    die "restore plan is not an object\n" unless ref($plan) eq "HASH";
    die "restore plan has no rootfs\n" unless defined($plan->{rootfs}) && !ref($plan->{rootfs});
    die "restore plan has no current rootfs volume\n"
      unless defined($plan->{current_rootfs_volume}) && !ref($plan->{current_rootfs_volume});
    die "restore plan mounts are not an array\n" unless ref($plan->{mounts}) eq "ARRAY";
    die "restore plan preserve list is not an array\n" unless ref($plan->{preserve}) eq "ARRAY";
    die "restore plan storages are not an array\n" unless ref($plan->{storages}) eq "ARRAY";

    print "$plan->{rootfs}\0";
    print "$plan->{current_rootfs_volume}\0";
    print scalar(@{$plan->{mounts}}) . "\0";
    for my $mount (@{$plan->{mounts}}) {
      die "invalid restore mount entry\n" unless ref($mount) eq "HASH";
      die "restore mount has no key or value\n"
        unless defined($mount->{key}) && defined($mount->{value});
      print "$mount->{key}\0$mount->{value}\0";
    }

    print scalar(@{$plan->{preserve}}) . "\0";
    for my $item (@{$plan->{preserve}}) {
      die "invalid preserve entry\n" unless ref($item) eq "HASH";
      die "preserve entry has no key, volume, or value\n"
        unless defined($item->{key}) && defined($item->{volume}) && defined($item->{value});
      print "$item->{key}\0$item->{volume}\0$item->{value}\0";
    }

    print scalar(@{$plan->{storages}}) . "\0";
    for my $storage (@{$plan->{storages}}) {
      die "invalid restore storage entry\n" if ref($storage) || !length($storage);
      print "$storage\0";
    }
  '
)

index=0
(( ${#fields[@]} >= 5 )) || fail "restore plan returned too few fields"

rootfs_arg="${fields[index++]}"
original_rootfs_volume="${fields[index++]}"
mount_count="${fields[index++]}"
[[ "$mount_count" =~ ^[0-9]+$ ]] || fail "restore plan returned invalid mount count"

restore_command=(pct restore "$vmid" "$backup_volume" --rootfs "$rootfs_arg" --force 1)

for ((n = 0; n < mount_count; n++)); do
  (( index + 1 < ${#fields[@]} )) || fail "restore plan mount list is truncated"
  key="${fields[index++]}"
  value="${fields[index++]}"
  [[ "$key" =~ ^mp[0-9]+$ ]] || fail "restore plan returned invalid mount key: $key"
  restore_command+=("--$key" "$value")
done

(( index < ${#fields[@]} )) || fail "restore plan has no preserve count"
preserve_count="${fields[index++]}"
[[ "$preserve_count" =~ ^[0-9]+$ ]] || fail "restore plan returned invalid preserve count"

preserve_keys=()
preserve_volumes=()
preserve_values=()
for ((n = 0; n < preserve_count; n++)); do
  (( index + 2 < ${#fields[@]} )) || fail "restore plan preserve list is truncated"
  preserve_keys+=("${fields[index++]}")
  preserve_volumes+=("${fields[index++]}")
  preserve_values+=("${fields[index++]}")
done

(( index < ${#fields[@]} )) || fail "restore plan has no storage count"
storage_count="${fields[index++]}"
[[ "$storage_count" =~ ^[0-9]+$ ]] || fail "restore plan returned invalid storage count"

storages=()
for ((n = 0; n < storage_count; n++)); do
  (( index < ${#fields[@]} )) || fail "restore plan storage list is truncated"
  storages+=("${fields[index++]}")
done

(( index == ${#fields[@]} )) || fail "restore plan returned unexpected trailing data"

for storage in "${storages[@]}"; do
  pvesm status --storage "$storage" >/dev/null 2>&1 || \
    fail "required restore storage is unavailable: $storage"
done

current_state="$(pct status "$vmid" 2>/dev/null)" || fail "could not read LXC $vmid state before restore"
current_state="${current_state#status: }"
[[ "$current_state" == stopped ]] || fail "LXC $vmid must be stopped before restore (current state: $current_state)"

if [[ "$dry_run" == true ]]; then
  printf 'restore=planned vmid=%s backup=%s\n' "$vmid" "$backup_volume"
  printf 'command='
  printf '%q ' "${restore_command[@]}"
  printf '\n'
  exit 0
fi

before_config="$(pct config "$vmid" 2>&1)" || fail "could not capture LXC $vmid configuration before restore"

"${restore_command[@]}"
restore_result=$?
if (( restore_result != 0 )); then
  printf 'ERROR: pct restore failed for LXC %s (exit code: %s)\n' "$vmid" "$restore_result" >&2
  exit "$restore_result"
fi

for ((n = 0; n < preserve_count; n++)); do
  key="${preserve_keys[n]}"
  expected_volume="${preserve_volumes[n]}"
  expected_value="${preserve_values[n]}"

  current_value="$(pct config "$vmid" | sed -n "s/^${key}: //p")" || \
    fail "could not verify preserved mount point $key after restore"

  [[ -n "$current_value" ]] || fail "preserved mount point $key is missing after restore"

  current_volume="${current_value%%,*}"
  [[ "$current_volume" == "$expected_volume" ]] || \
    fail "preserved mount point $key changed volume after restore (expected $expected_volume, got $current_volume)"

  [[ "$current_value" == "$expected_value" ]] || \
    fail "preserved mount point $key configuration differs after restore"
done

new_config="$(pct config "$vmid" 2>&1)" || fail "could not read LXC $vmid configuration after restore"
[[ -n "$new_config" ]] || fail "LXC $vmid configuration is empty after restore"

new_rootfs="$(printf '%s\n' "$new_config" | sed -n 's/^rootfs: //p')"
[[ -n "$new_rootfs" ]] || fail "restored LXC $vmid has no rootfs"
new_rootfs_volume="${new_rootfs%%,*}"
[[ "$new_rootfs_volume" != "$original_rootfs_volume" ]] || \
  printf 'WARNING: restored LXC %s reused the same rootfs volume identifier: %s\n' "$vmid" "$new_rootfs_volume" >&2

printf 'restore=success vmid=%s backup=%s\n' "$vmid" "$backup_volume"
