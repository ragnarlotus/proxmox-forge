#!/bin/bash
# Description: Converts the single applicable Proxmox backup job into a validated one-target vzdump execution plan for an LXC.

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

[[ $# -eq 1 ]] || fail "usage: prepare.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

command -v vzdump >/dev/null 2>&1 || fail "vzdump is not available"
command -v perl >/dev/null 2>&1 || fail "perl is not available"
[[ -f "/etc/pve/lxc/${vmid}.conf" ]] || fail "LXC $vmid does not exist on this Proxmox host"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
policy_script="$script_dir/read-policy.sh"
[[ -r "$policy_script" ]] || fail "backup policy helper is not readable: $policy_script"

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

usage_text="$(vzdump help 2>&1)" || fail "could not read vzdump CLI usage"

VMID="$vmid" USAGE_TEXT="$usage_text" perl -MJSON::PP -e '
  use strict;
  use warnings;

  my $vmid = $ENV{VMID};
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

  die "could not discover vzdump CLI parameters\n" unless %accepted;

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

  if (defined $job->{id} && $accepted{"job-id"}) {
    push @params, { name => "job-id", value => "$job->{id}", source => "job" };
  }

  for my $key (sort keys %$job) {
    next if $skip{$key};
    next unless $accepted{$key};

    # This planner currently targets LXC. Proxmox documents fleecing as VM-only.
    next if $key eq "fleecing";

    my $value = cli_value($key, $job->{$key});
    next unless defined $value;
    push @params, { name => $key, value => $value, source => "job" };
  }

  my $plan = {
    vmid => "$vmid",
    parameters => \@params,
  };

  print JSON::PP->new->canonical(1)->pretty(1)->encode($plan);
' <<<"$jobs_json" || fail "could not build Proxmox backup execution plan for LXC $vmid"
