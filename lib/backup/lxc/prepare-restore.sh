#!/bin/bash
# Description: Builds a version-aware advanced pct restore plan that preserves each backed-up mount point's storage topology and identifies storage-backed mount points excluded from backup.

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

[[ $# -eq 2 ]] || fail "usage: prepare-restore.sh VMID BACKUP_VOLUME"
vmid="$1"
backup_volume="$2"

[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"
[[ "$backup_volume" == *:* ]] || fail "BACKUP_VOLUME must be a Proxmox volume ID"

for command_name in pvesm perl; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is not available"
done

[[ -f "/etc/pve/lxc/${vmid}.conf" ]] || fail "LXC $vmid does not exist on this Proxmox host"

backup_config="$(pvesm extractconfig "$backup_volume" 2>&1)"
extract_result=$?
if (( extract_result != 0 )); then
  printf '%s\n' "$backup_config" >&2
  exit "$extract_result"
fi

VMID="$vmid" BACKUP_VOLUME="$backup_volume" BACKUP_CONFIG="$backup_config" \
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
    vmid => "$vmid",
    backup_volume => $ENV{BACKUP_VOLUME},
    rootfs => print_mountpoint("rootfs", $rootfs, 1),
    current_rootfs_volume => $current_rootfs->{volume},
    mounts => \@mounts,
    preserve => \@preserve,
    storages => [sort keys %storages],
  };

  print JSON::PP->new->canonical(1)->encode($plan);
' || fail "could not build safe restore plan for LXC $vmid"
