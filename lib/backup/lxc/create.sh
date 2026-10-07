#!/bin/bash
# Description: Creates one synchronous LXC backup using the applicable Proxmox backup policy and returns the exact created recovery volume.

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

list_backup_volumes() {
  local storage="$1"
  local output result line volume

  output="$(LC_ALL=C pvesm list "$storage" --vmid "$vmid" --content backup 2>&1)"
  result=$?

  if (( result != 0 )); then
    printf '%s\n' "$output" >&2
    return "$result"
  fi

  while IFS= read -r line; do
    read -r volume _ <<<"$line"

    case "${volume:-}" in
      "$storage":*) printf '%s\n' "$volume" ;;
    esac
  done <<<"$output" | LC_ALL=C sort -u
}

[[ $# -eq 1 ]] || fail "usage: create.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

for command_name in vzdump pvesh pvesm perl hostname; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is not available"
done

[[ -f "/etc/pve/lxc/${vmid}.conf" ]] || fail "LXC $vmid does not exist on this Proxmox host"

node="$(hostname -s)" || fail "could not determine local Proxmox node name"
[[ -n "$node" ]] || fail "local Proxmox node name is empty"

jobs_json="$(pvesh get /cluster/backup --output-format json)" || \
  fail "could not read Proxmox backup jobs through pvesh"

usage_text="$(vzdump help 2>&1)" || fail "could not read vzdump CLI usage"

mapfile -d '' -t fields < <(
  JOBS_JSON="$jobs_json" USAGE_TEXT="$usage_text" VMID="$vmid" NODE="$node" \
  perl -MJSON::PP -e '
    use strict;
    use warnings;

    my $vmid = $ENV{VMID};
    my $node = $ENV{NODE};
    my $usage = $ENV{USAGE_TEXT};
    my $jobs = decode_json($ENV{JOBS_JSON});

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

    die "no enabled Proxmox backup job applies to LXC $vmid\n" unless @matches;
    die "multiple enabled Proxmox backup jobs apply to LXC $vmid; Forge will not choose implicitly\n"
      if @matches > 1;

    my $job = $matches[0];

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
      push @params, ["job-id", "$job->{id}"];
    }

    for my $key (sort keys %$job) {
      next if $skip{$key};
      next unless $accepted{$key};

      # Forge currently creates LXC backups; Proxmox documents fleecing as VM-only.
      next if $key eq "fleecing";

      my $value = cli_value($key, $job->{$key});
      next unless defined $value;
      push @params, [$key, $value];
    }

    my @storage = map { $_->[1] } grep { $_->[0] eq "storage" } @params;
    die "backup plan must contain exactly one storage parameter\n" unless @storage == 1;
    die "backup storage value is missing\n" unless length($storage[0]);

    print "$storage[0]\0";

    for my $param (@params) {
      print "--$param->[0]\0$param->[1]\0";
    }
  '
)

(( ${#fields[@]} >= 3 )) || fail "backup policy returned no execution parameters"
(( (${#fields[@]} - 1) % 2 == 0 )) || fail "backup policy returned malformed execution parameters"

storage="${fields[0]}"
command=(vzdump "$vmid")

for ((i = 1; i < ${#fields[@]}; i += 2)); do
  command+=("${fields[i]}" "${fields[i + 1]}")
done

before_backups="$(list_backup_volumes "$storage")" || \
  fail "could not list existing backups for LXC $vmid on storage $storage"

"${command[@]}"
create_result=$?

if (( create_result != 0 )); then
  printf 'ERROR: Proxmox vzdump backup failed for LXC %s (exit code: %s)\n' \
    "$vmid" "$create_result" >&2
  exit "$create_result"
fi

after_backups="$(list_backup_volumes "$storage")" || \
  fail "backup succeeded but available backups could not be listed afterwards"

declare -A existing=()
while IFS= read -r volume; do
  [[ -n "$volume" ]] && existing["$volume"]=1
done <<<"$before_backups"

new_backups=()
while IFS= read -r volume; do
  [[ -n "$volume" ]] || continue
  [[ -n "${existing[$volume]+x}" ]] || new_backups+=("$volume")
done <<<"$after_backups"

if (( ${#new_backups[@]} != 1 )); then
  fail "backup task succeeded but the exact created recovery volume could not be identified (new volumes: ${#new_backups[@]})"
fi

backup_volume="${new_backups[0]}"
printf 'backup=success vmid=%s storage=%s volume=%s\n' \
  "$vmid" "$storage" "$backup_volume"
