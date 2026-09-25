#!/bin/bash
# Description: Executes one prepared Proxmox backup request for an LXC, waits for the authoritative task result, and returns the exact created recovery volume.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || fail "usage: create.sh VMID [--dry-run]"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

dry_run=false
if [[ $# -eq 2 ]]; then
  [[ "$2" == --dry-run ]] || fail "unknown option '$2'"
  dry_run=true
fi

command -v pvesh >/dev/null 2>&1 || fail "pvesh is not available"
command -v perl >/dev/null 2>&1 || fail "perl is not available"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
lib_dir="$(cd "$script_dir/.." && pwd)" || fail "could not determine lib directory"
plan_script="$script_dir/prepare.sh"
list_script="$script_dir/list-volumes.sh"
wait_script="$lib_dir/tasks/wait.sh"

for helper in "$plan_script" "$list_script" "$wait_script"; do
  [[ -r "$helper" ]] || fail "required backup helper is not readable: $helper"
done

plan_json="$(bash "$plan_script" "$vmid" --json)" || \
  fail "could not prepare Proxmox backup for LXC $vmid"

mapfile -d '' -t fields < <(
  PLAN_JSON="$plan_json" perl -MJSON::PP -e '
    use strict;
    use warnings;

    my $plan = decode_json($ENV{PLAN_JSON});
    die "backup plan is not an object\n" unless ref($plan) eq "HASH";
    die "backup plan has no endpoint\n" unless defined($plan->{endpoint}) && !ref($plan->{endpoint}) && length($plan->{endpoint});
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

    print "$plan->{endpoint}\0$storage[0]\0";

    for my $param (@{$plan->{parameters}}) {
      print "--$param->{name}\0$param->{value}\0";
    }
  '
) || fail "could not decode Proxmox backup plan"

(( ${#fields[@]} >= 4 )) || fail "backup plan returned no execution parameters"
(( (${#fields[@]} - 2) % 2 == 0 )) || fail "backup plan returned malformed execution parameters"

endpoint="${fields[0]}"
storage="${fields[1]}"
command=(pvesh create "$endpoint")

for ((i = 2; i < ${#fields[@]}; i += 2)); do
  command+=("${fields[i]}" "${fields[i + 1]}")
done

if [[ "$dry_run" == true ]]; then
  printf 'execution=planned vmid=%s storage=%s\n' "$vmid" "$storage"
  printf 'command='
  printf '%q ' "${command[@]}"
  printf '\n'
  exit 0
fi

before_backups="$(bash "$list_script" "$storage" "$vmid")" || \
  fail "could not list existing backups for LXC $vmid on storage $storage"

output="$("${command[@]}" 2>&1)"
create_result=$?
printf '%s\n' "$output"

upid="$(printf '%s\n' "$output" | sed -n 's/^\(UPID:[^[:space:]]*\)$/\1/p' | tail -n 1)"

if [[ -z "$upid" ]]; then
  if (( create_result != 0 )); then
    printf 'ERROR: Proxmox backup request failed before returning a task UPID (exit code: %s)\n' "$create_result" >&2
    exit "$create_result"
  fi

  fail "Proxmox backup request returned no task UPID"
fi

# The UPID is not success by itself. The task result is authoritative.
bash "$wait_script" "$upid"
wait_result=$?
(( wait_result == 0 )) || exit "$wait_result"

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
printf 'backup=success vmid=%s storage=%s volume=%s upid=%s\n' \
  "$vmid" "$storage" "$backup_volume" "$upid"
