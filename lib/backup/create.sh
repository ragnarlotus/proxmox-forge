#!/bin/bash

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
plan_script="$script_dir/build-plan.sh"
wait_script="$lib_dir/proxmox-task-wait.sh"
[[ -r "$plan_script" ]] || fail "backup plan helper is not readable: $plan_script"
[[ -r "$wait_script" ]] || fail "task wait helper is not readable: $wait_script"

plan_json="$(bash "$plan_script" "$vmid" --json)" || \
  fail "could not build Proxmox backup plan for LXC $vmid"

mapfile -d '' -t fields < <(
  PLAN_JSON="$plan_json" perl -MJSON::PP -e '
    use strict;
    use warnings;

    my $plan = decode_json($ENV{PLAN_JSON});
    die "backup plan is not an object\n" unless ref($plan) eq "HASH";
    die "backup plan has no endpoint\n" unless defined $plan->{endpoint};
    die "backup plan parameters are not an array\n" unless ref($plan->{parameters}) eq "ARRAY";

    print "$plan->{endpoint}\0";

    for my $param (@{$plan->{parameters}}) {
      die "backup plan parameter is not an object\n" unless ref($param) eq "HASH";
      die "backup plan parameter has no name\n" unless defined $param->{name};
      die "backup plan parameter has no value\n" unless defined $param->{value};
      die "invalid backup parameter name\n" unless $param->{name} =~ /^[a-z0-9][a-z0-9-]*$/;

      print "--$param->{name}\0$param->{value}\0";
    }
  '
) || fail "could not decode Proxmox backup plan"

(( ${#fields[@]} >= 3 )) || fail "backup plan returned no execution parameters"
(( (${#fields[@]} - 1) % 2 == 0 )) || fail "backup plan returned malformed execution parameters"

endpoint="${fields[0]}"
command=(pvesh create "$endpoint")

for ((i = 1; i < ${#fields[@]}; i += 2)); do
  command+=("${fields[i]}" "${fields[i + 1]}")
done

if [[ "$dry_run" == true ]]; then
  printf 'execution=planned vmid=%s\n' "$vmid"
  printf 'command='
  printf '%q ' "${command[@]}"
  printf '\n'
  exit 0
fi

output="$("${command[@]}" 2>&1)"
create_result=$?
printf '%s\n' "$output"

upid="$(printf '%s\n' "$output" | sed -n 's/^\(UPID:[^[:space:]]*\)$/\1/p' | tail -n 1)"

if [[ -z "$upid" ]]; then
  if (( create_result != 0 )); then
    fail "Proxmox backup request failed before returning a task UPID"
  fi
  fail "Proxmox backup request returned no task UPID"
fi

# The UPID is not success by itself. The task result is authoritative.
bash "$wait_script" "$upid"
