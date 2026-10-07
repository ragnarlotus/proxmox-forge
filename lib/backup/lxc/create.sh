#!/bin/bash
# Description: Executes one prepared synchronous vzdump backup for an LXC and returns the exact created recovery volume.

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

[[ $# -eq 1 ]] || fail "usage: create.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

command -v vzdump >/dev/null 2>&1 || fail "vzdump is not available"
command -v perl >/dev/null 2>&1 || fail "perl is not available"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
plan_script="$script_dir/prepare.sh"
list_script="$script_dir/list-volumes.sh"

for helper in "$plan_script" "$list_script"; do
  [[ -r "$helper" ]] || fail "required backup helper is not readable: $helper"
done

plan_json="$(bash "$plan_script" "$vmid")" || \
  fail "could not prepare Proxmox backup for LXC $vmid"

mapfile -d '' -t fields < <(
  PLAN_JSON="$plan_json" perl -MJSON::PP -e '
    use strict;
    use warnings;

    my $plan = decode_json($ENV{PLAN_JSON});
    die "backup plan is not an object\n" unless ref($plan) eq "HASH";
    die "backup plan parameters are not an array\n" unless ref($plan->{parameters}) eq "ARRAY";

    my @storage;

    for my $param (@{$plan->{parameters}}) {
      die "backup plan parameter is not an object\n" unless ref($param) eq "HASH";
      die "backup plan parameter has no name\n" unless defined $param->{name};
      die "backup plan parameter has no value\n" unless defined $param->{value};
      die "invalid backup parameter name\n" unless $param->{name} =~ /^[a-z0-9][a-z0-9-]*$/;
      die "backup plan parameter value must be scalar\n" if ref($param->{value});

      push @storage, $param->{value} if $param->{name} eq "storage";
    }

    die "backup plan must contain exactly one storage parameter\n" unless @storage == 1;
    die "backup storage value is missing\n" unless length($storage[0]);

    print "$storage[0]\0";

    for my $param (@{$plan->{parameters}}) {
      print "--$param->{name}\0$param->{value}\0";
    }
  '
) || fail "could not decode Proxmox backup plan"

(( ${#fields[@]} >= 3 )) || fail "backup plan returned no execution parameters"
(( (${#fields[@]} - 1) % 2 == 0 )) || fail "backup plan returned malformed execution parameters"

storage="${fields[0]}"
command=(vzdump "$vmid")

for ((i = 1; i < ${#fields[@]}; i += 2)); do
  command+=("${fields[i]}" "${fields[i + 1]}")
done

before_backups="$(bash "$list_script" "$storage" "$vmid")" || \
  fail "could not list existing backups for LXC $vmid on storage $storage"

"${command[@]}"
create_result=$?

if (( create_result != 0 )); then
  printf 'ERROR: Proxmox vzdump backup failed for LXC %s (exit code: %s)\n' \
    "$vmid" "$create_result" >&2
  exit "$create_result"
fi

after_backups="$(bash "$list_script" "$storage" "$vmid")" || \
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
