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

[[ $# -eq 2 ]] || fail "usage: restore.sh VMID BACKUP_VOLUME"
vmid="$1"
backup_volume="$2"

[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"
[[ "$backup_volume" == *:* ]] || fail "BACKUP_VOLUME must be a Proxmox volume ID"

for command_name in pct pvesm perl; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is not available"
done

[[ -f "/etc/pve/lxc/${vmid}.conf" ]] || fail "LXC $vmid does not exist on this Proxmox host"

backup_config="$(pvesm extractconfig "$backup_volume" 2>&1)"
extract_result=$?
if (( extract_result != 0 )); then
  printf '%s\n' "$backup_config" >&2
  exit "$extract_result"
fi

plan_json="$(
  VMID="$vmid" BACKUP_CONFIG="$backup_config" \
  perl -MPVE::LXC::Config -MPVE::Storage -MJSON::PP -e '
    use strict;
    use warnings;

    my $vmid = $ENV{VMID};
    my $raw = $ENV{BACKUP_CONFIG};

    my $backup = PVE::LXC::Config::parse_pct_config("/etc/pve/lxc/$vmid.conf", $raw, 1);
    die "could not parse backed-up LXC configuration\n" unless ref($backup) eq "HASH";

    my $current = PVE::LXC::Config->load_config($vmid);
    die "could not read current LXC configuration\n" unless ref($current) eq "HASH";

    my $pending = $current->{pending} // {};
    if (ref($pending) eq "HASH") {
      for my $key (keys %$pending) {
        next if $key eq "delete";
        die "current configuration has pending storage change $key; automatic restore is unsafe\n"
          if $key eq "rootfs" || $key =~ /^mp\d+$/ || $key =~ /^unused\d+$/;
      }

      if (defined($pending->{delete})) {
        for my $key (split /,/, $pending->{delete}) {
          $key =~ s/^\s+|\s+$//g;
          die "current configuration has pending storage deletion $key; automatic restore is unsafe\n"
            if $key eq "rootfs" || $key =~ /^mp\d+$/ || $key =~ /^unused\d+$/;
        }
      }
    }

    sub gib_value {
      my ($bytes) = @_;
      die "mount point size is missing\n" unless defined($bytes) && $bytes > 0;

      my $value = sprintf("%.9f", $bytes / (1024 * 1024 * 1024));
      $value =~ s/0+$//;
      $value =~ s/\.$//;
      die "mount point size could not be converted to GiB\n" unless length($value);
      return $value;
    }

    sub print_mountpoint {
      my ($key, $mountpoint, $allocate) = @_;
      my %copy = %$mountpoint;

      delete $copy{type};

      if ($allocate) {
        die "$key is not storage-backed\n" unless $mountpoint->{type} eq "volume";
        my ($storage) = PVE::Storage::parse_volume_id($mountpoint->{volume});
        die "could not determine storage for $key\n" unless defined($storage) && length($storage);

        $copy{volume} = "$storage:" . gib_value($mountpoint->{size});
        delete $copy{size};
      }

      return PVE::LXC::Config->print_ct_mountpoint(\%copy, $key eq "rootfs");
    }

    my $rootfs_raw = $backup->{rootfs};
    die "backed-up configuration has no rootfs\n" unless defined($rootfs_raw);

    my $rootfs = PVE::LXC::Config->parse_volume("rootfs", $rootfs_raw);
    die "automatic restore requires a storage-backed rootfs\n" unless $rootfs->{type} eq "volume";

    my $current_rootfs_raw = $current->{rootfs};
    die "current configuration has no rootfs\n" unless defined($current_rootfs_raw);
    my $current_rootfs = PVE::LXC::Config->parse_volume("rootfs", $current_rootfs_raw);
    die "current rootfs is not storage-backed\n" unless $current_rootfs->{type} eq "volume";

    my @mounts;
    my @preserve;
    my %storages;

    my ($root_storage) = PVE::Storage::parse_volume_id($rootfs->{volume});
    $storages{$root_storage} = 1;

    sub mp_index {
      my ($key) = @_;
      $key =~ /^mp(\d+)$/ or die "invalid mount point key $key\n";
      return $1;
    }

    for my $key (sort { mp_index($a) <=> mp_index($b) } grep { /^mp\d+$/ } keys %$backup) {
      my $mountpoint = PVE::LXC::Config->parse_volume($key, $backup->{$key});
      my $value;

      if ($mountpoint->{type} eq "volume") {
        my ($storage) = PVE::Storage::parse_volume_id($mountpoint->{volume});
        die "could not determine storage for $key\n" unless defined($storage) && length($storage);
        $storages{$storage} = 1;

        if (PVE::LXC::Config->mountpoint_backup_enabled($key, $mountpoint)) {
          $value = print_mountpoint($key, $mountpoint, 1);
        } else {
          my $current_raw = $current->{$key};
          die "$key is excluded from backup but is missing from the current configuration\n"
            unless defined($current_raw);

          my $current_mp = PVE::LXC::Config->parse_volume($key, $current_raw);
          die "$key is excluded from backup but its current mount point is not storage-backed\n"
            unless $current_mp->{type} eq "volume";
          die "$key changed volume since the recovery backup was created; refusing automatic restore\n"
            unless $current_mp->{volume} eq $mountpoint->{volume};

          $value = print_mountpoint($key, $mountpoint, 0);
          push @preserve, {
            key => $key,
            volume => $mountpoint->{volume},
            value => $value,
          };
        }
      } else {
        # Bind and device mount points carry configuration only; their data is external.
        $value = print_mountpoint($key, $mountpoint, 0);
      }

      push @mounts, { key => $key, value => $value };
    }

    my $plan = {
      rootfs => print_mountpoint("rootfs", $rootfs, 1),
      current_rootfs_volume => $current_rootfs->{volume},
      mounts => \@mounts,
      preserve => \@preserve,
      storages => [sort keys %storages],
    };

    print JSON::PP->new->canonical(1)->encode($plan);
  '
)" || fail "could not build safe restore plan for LXC $vmid"

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
      print "$item->{volume}\0";
    }

    print scalar(@{$plan->{storages}}) . "\0";
    for my $storage (@{$plan->{storages}}) {
      die "invalid restore storage entry\n" if ref($storage) || !length($storage);
      print "$storage\0";
    }
  '
)

index=0
(( ${#fields[@]} >= 4 )) || fail "restore plan returned too few fields"

rootfs_arg="${fields[index++]}"
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

preserve_volumes=()
for ((n = 0; n < preserve_count; n++)); do
  (( index < ${#fields[@]} )) || fail "restore plan preserve list is truncated"
  preserve_volumes+=("${fields[index++]}")
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
