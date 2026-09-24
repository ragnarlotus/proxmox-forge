#!/bin/bash

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: proxmox-backup-plan.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

command -v pvesh >/dev/null 2>&1 || fail "pvesh is not available"
command -v perl >/dev/null 2>&1 || fail "perl is not available"
[[ -f "/etc/pve/lxc/${vmid}.conf" ]] || fail "LXC $vmid does not exist on this Proxmox host"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
policy_script="$script_dir/proxmox-backup-policy.sh"
[[ -r "$policy_script" ]] || fail "backup policy helper is not readable: $policy_script"

node="$(hostname -s)" || fail "could not determine local Proxmox node name"
[[ -n "$node" ]] || fail "local Proxmox node name is empty"

policy_output="$(bash "$policy_script" "$vmid")" || fail "could not resolve Proxmox backup policy for LXC $vmid"
match_count="$(printf '%s\n' "$policy_output" | sed -n 's/^match_count=//p' | head -n 1)"
[[ "$match_count" =~ ^[0-9]+$ ]] || fail "backup policy helper returned an invalid match count"

case "$match_count" in
  0)
    fail "no enabled Proxmox backup job applies to LXC $vmid"
    ;;
  1)
    ;;
  *)
    fail "multiple enabled Proxmox backup jobs apply to LXC $vmid; Forge will not choose implicitly"
    ;;
esac

jobs_json="$(printf '%s\n' "$policy_output" | sed '1d')"
[[ -n "$jobs_json" ]] || fail "backup policy helper returned no job data"

usage_text="$(pvesh usage "/nodes/$node/vzdump" -v)" || fail "could not read vzdump endpoint schema from Proxmox"

VMID="$vmid" NODE="$node" USAGE_TEXT="$usage_text" perl -MJSON::PP -e '
  use strict;
  use warnings;

  my $vmid = $ENV{VMID};
  my $node = $ENV{NODE};
  my $usage = $ENV{USAGE_TEXT};
  my $jobs = decode_json(do { local $/; <STDIN> });

  die "policy data is not an array\n" unless ref($jobs) eq "ARRAY";
  die "policy data does not contain exactly one job\n" unless @$jobs == 1;

  my $job = $jobs->[0];
  die "policy job is not an object\n" unless ref($job) eq "HASH";

  my %accepted;
  while ($usage =~ /^\s*--([a-z0-9][a-z0-9-]*)\b/mg) {
    $accepted{$1} = 1;
  }

  die "could not discover vzdump endpoint parameters\n" unless %accepted;

  my %skip = map { $_ => 1 } qw(
    all
    enabled
    exclude
    id
    next-run
    node
    repeat-missed
    schedule
    type
    vmid
  );

  sub cli_value {
    my ($key, $value) = @_;

    return undef unless defined $value;

    if (!ref($value)) {
      return "$value";
    }

    if (ref($value) eq "HASH") {
      return join ",", map {
        my $v = $value->{$_};
        die "unsupported nested value in backup option $key\n" if ref($v);
        $_ . "=" . (defined($v) ? $v : "")
      } sort keys %$value;
    }

    die "unsupported Proxmox backup option shape for $key\n";
  }

  my @params;
  push @params, ["vmid", $vmid, "target"];

  if (defined $job->{id} && $accepted{"job-id"}) {
    push @params, ["job-id", "$job->{id}", "job"];
  }

  for my $key (sort keys %$job) {
    next if $skip{$key};
    next unless $accepted{$key};

    # This planner currently targets LXC. Proxmox documents fleecing as VM-only.
    next if $key eq "fleecing";

    my $value = cli_value($key, $job->{$key});
    next unless defined $value;
    push @params, [$key, $value, "job"];
  }

  print "vmid=$vmid\n";
  print "node=$node\n";
  print "job_id=" . (defined($job->{id}) ? $job->{id} : "unknown") . "\n";
  print "endpoint=/nodes/$node/vzdump\n";

  for my $param (@params) {
    my ($key, $value, $source) = @$param;
    $value =~ s/\\/\\\\/g;
    $value =~ s/\n/\\n/g;
    print "parameter=$key source=$source value=$value\n";
  }
' <<<"$jobs_json" || fail "could not build Proxmox backup execution plan for LXC $vmid"
