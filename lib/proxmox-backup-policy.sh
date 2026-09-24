#!/bin/bash

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: proxmox-backup-policy.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

command -v pvesh >/dev/null 2>&1 || fail "pvesh is not available"
command -v perl >/dev/null 2>&1 || fail "perl is not available"
[[ -f "/etc/pve/lxc/${vmid}.conf" ]] || fail "LXC $vmid does not exist on this Proxmox host"

node="$(hostname -s)" || fail "could not determine local Proxmox node name"
[[ -n "$node" ]] || fail "local Proxmox node name is empty"

jobs_json="$(pvesh get /cluster/backup --output-format json)" || \
  fail "could not read Proxmox backup jobs through pvesh"

VMID="$vmid" NODE="$node" perl -MJSON::PP -e '
  use strict;
  use warnings;

  my $vmid = $ENV{VMID};
  my $node = $ENV{NODE};
  my $jobs = decode_json(do { local $/; <STDIN> });

  die "backup API response is not an array\n" unless ref($jobs) eq "ARRAY";

  sub contains_vmid {
    my ($value, $wanted) = @_;
    return 0 unless defined $value;

    for my $item (split /[,\s]+/, "$value") {
      return 1 if length($item) && $item eq $wanted;
    }

    return 0;
  }

  my @matches;

  for my $job (@$jobs) {
    next unless ref($job) eq "HASH";
    next if exists($job->{enabled}) && !$job->{enabled};
    next if defined($job->{node}) && $job->{node} ne $node;

    my $matches = 0;

    if (defined $job->{vmid}) {
      $matches = contains_vmid($job->{vmid}, $vmid);
    }
    elsif ($job->{all}) {
      $matches = !contains_vmid($job->{exclude}, $vmid);
    }

    push @matches, $job if $matches;
  }

  print "match_count=" . scalar(@matches) . "\n";
  print JSON::PP->new->canonical(1)->pretty(1)->encode(\@matches);
' <<<"$jobs_json" || fail "could not evaluate Proxmox backup policy for LXC $vmid"
