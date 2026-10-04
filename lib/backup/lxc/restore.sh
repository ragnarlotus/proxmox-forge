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

restore_storages=()
for ((n = 0; n < storage_count; n++)); do
  (( index < ${#fields[@]} )) || fail "restore plan storage list is truncated"
  restore_storages+=("${fields[index++]}")
done

(( index == ${#fields[@]} )) || fail "restore plan returned unexpected trailing fields"

for storage in "${restore_storages[@]}"; do
  pvesm status --storage "$storage" >/dev/null 2>&1 || \
    fail "restore storage is not currently available: $storage"
done

for volume in "${preserve_volumes[@]}"; do
  pvesm path "$volume" >/dev/null 2>&1 || \
    fail "excluded mount-point volume is not currently available: $volume"
done

restore_help="$(pct help restore --verbose 2>&1)" || fail "could not read pct restore capabilities"
printf '%s\n' "$restore_help" | grep -q -- '--rootfs' || fail "installed pct restore does not expose --rootfs"
printf '%s\n' "$restore_help" | grep -q -- '--mp\[n\]' || fail "installed pct restore does not expose --mp[n]"
printf '%s\n' "$restore_help" | grep -q -- '--force' || fail "installed pct restore does not expose --force"

if [[ "$dry_run" == true ]]; then
  printf 'restore=planned vmid=%s backup=%s preserved_mounts=%s\n' \
    "$vmid" "$backup_volume" "$preserve_count"
  for ((n = 0; n < preserve_count; n++)); do
    printf 'preserve=%s volume=%s\n' "${preserve_keys[n]}" "${preserve_volumes[n]}"
  done
  printf 'command='
  printf '%q ' "${restore_command[@]}"
  printf '\n'
  exit 0
fi

state_output="$(pct status "$vmid" 2>&1)"
state_result=$?
if (( state_result != 0 )); then
  printf '%s\n' "$state_output" >&2
  exit "$state_result"
fi
[[ "$state_output" == 'status: stopped' ]] || fail "LXC $vmid must be stopped before automatic restore"

# pct restore --force destroys every storage-backed volume still referenced by
# the old active configuration. Temporarily remove only the excluded volumes
# that must survive; do not move them to unusedN, because unused volumes are
# also destroyed by Proxmox during overwrite restore.
if (( preserve_count > 0 )); then
  VMID="$vmid" PLAN_JSON="$plan_json" perl -MPVE::LXC::Config -MJSON::PP -e '
    use strict;
    use warnings;

    my $vmid = $ENV{VMID};
    my $plan = decode_json($ENV{PLAN_JSON});
    my $preserve = $plan->{preserve};
    die "invalid preserve plan\n" unless ref($preserve) eq "ARRAY";

    PVE::LXC::Config->lock_config(
      $vmid,
      sub {
        my $conf = PVE::LXC::Config->load_config($vmid);

        for my $item (@$preserve) {
          my $key = $item->{key};
          my $volume = $item->{volume};
          my $raw = $conf->{$key};
          die "$key disappeared before restore\n" unless defined($raw);

          my $mp = PVE::LXC::Config->parse_volume($key, $raw);
          die "$key changed before restore\n"
            unless $mp->{type} eq "volume" && $mp->{volume} eq $volume;

          for my $other (keys %$conf) {
            next if $other eq $key;
            next unless $other eq "rootfs" || $other =~ /^mp\d+$/ || $other =~ /^unused\d+$/;
            my $other_mp = PVE::LXC::Config->parse_volume($other, $conf->{$other}, 1);
            next unless $other_mp && $other_mp->{type} eq "volume";
            die "volume $volume is also referenced by $other; refusing to hide it\n"
              if $other_mp->{volume} eq $volume;
          }
        }

        delete $conf->{$_->{key}} for @$preserve;
        PVE::LXC::Config->write_config($vmid, $conf);
      },
    );
  '
  mask_result=$?
  (( mask_result == 0 )) || exit "$mask_result"
fi

"${restore_command[@]}"
restore_result=$?

if (( restore_result != 0 )); then
  # If Proxmox failed before replacing the old rootfs, restore the temporarily
  # hidden references so the pre-restore container configuration remains usable.
  VMID="$vmid" PLAN_JSON="$plan_json" perl -MPVE::LXC::Config -MJSON::PP -e '
    use strict;
    use warnings;

    my $vmid = $ENV{VMID};
    my $plan = decode_json($ENV{PLAN_JSON});
    my $preserve = $plan->{preserve};
    exit 0 unless ref($preserve) eq "ARRAY" && @$preserve;
    exit 0 unless -f "/etc/pve/lxc/$vmid.conf";

    eval {
      PVE::LXC::Config->lock_config(
        $vmid,
        sub {
          my $conf = PVE::LXC::Config->load_config($vmid);
          my $root_raw = $conf->{rootfs} // return;
          my $root = PVE::LXC::Config->parse_volume("rootfs", $root_raw, 1) // return;
          return unless $root->{type} eq "volume";
          return unless $root->{volume} eq $plan->{current_rootfs_volume};

          for my $item (@$preserve) {
            next if defined($conf->{$item->{key}});
            $conf->{$item->{key}} = $item->{value};
          }
          PVE::LXC::Config->write_config($vmid, $conf);
        },
      );
    };
    warn "WARNING: could not restore hidden mount-point references after failed restore: $@" if $@;
  '

  printf 'ERROR: restore failed for LXC %s from %s (exit code: %s)\n' \
    "$vmid" "$backup_volume" "$restore_result" >&2
  exit "$restore_result"
fi

VMID="$vmid" PLAN_JSON="$plan_json" perl -MPVE::LXC::Config -MJSON::PP -e '
  use strict;
  use warnings;

  my $vmid = $ENV{VMID};
  my $plan = decode_json($ENV{PLAN_JSON});
  my $conf = PVE::LXC::Config->load_config($vmid);

  for my $item (@{$plan->{preserve}}) {
    my $raw = $conf->{$item->{key}};
    die "$item->{key} is missing after restore\n" unless defined($raw);
    my $mp = PVE::LXC::Config->parse_volume($item->{key}, $raw);
    die "$item->{key} does not reference preserved volume $item->{volume} after restore\n"
      unless $mp->{type} eq "volume" && $mp->{volume} eq $item->{volume};
  }
' || fail "restore completed but preserved mount-point validation failed"

printf 'restore=success vmid=%s backup=%s preserved_mounts=%s\n' \
  "$vmid" "$backup_volume" "$preserve_count"
