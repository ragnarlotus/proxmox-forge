#!/bin/bash
# Description: Executes one prepared Proxmox backup request for an LXC, waits for the authoritative task result, verifies that a running guest returns to its pre-backup service baseline, and returns the exact created recovery volume.

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
command -v pct >/dev/null 2>&1 || fail "pct is not available"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
lib_dir="$(cd "$script_dir/../.." && pwd)" || fail "could not determine lib directory"
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

status_output="$(pct status "$vmid" 2>/dev/null)" || \
  fail "could not read pre-backup state for LXC $vmid"
pre_backup_state="${status_output#status: }"

service_manager="none"
baseline_services=()

if [[ "$pre_backup_state" == running ]]; then
  pct exec "$vmid" -- sh -c 'exit 0' </dev/null || \
    fail "LXC $vmid is running but not ready before backup"

  if pct exec "$vmid" -- sh -c 'command -v systemctl >/dev/null 2>&1' </dev/null; then
    service_manager="systemd"
    baseline_output="$(
      pct exec "$vmid" -- \
        systemctl list-units --type=service --state=active --no-legend --no-pager --plain \
        </dev/null
    )" || fail "could not capture active systemd services before backup for LXC $vmid"

    mapfile -t baseline_services < <(
      printf '%s\n' "$baseline_output" |
        awk 'NF {print $1}' |
        LC_ALL=C sort -u
    )
  fi
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

if [[ "$pre_backup_state" == running ]]; then
  post_backup_ready=false
  failed_units=""
  inactive_services=()

  for ((attempt = 1; attempt <= 30; attempt++)); do
    status_output="$(pct status "$vmid" 2>/dev/null)" || status_output=""
    post_backup_state="${status_output#status: }"

    if [[ "$post_backup_state" == running ]] \
      && pct exec "$vmid" -- sh -c 'exit 0' </dev/null; then
      if [[ "$service_manager" != systemd ]]; then
        post_backup_ready=true
        break
      fi

      baseline_active=true
      if (( ${#baseline_services[@]} > 0 )); then
        pct exec "$vmid" -- \
          systemctl is-active --quiet "${baseline_services[@]}" \
          </dev/null || baseline_active=false
      fi

      failed_units="$(
        pct exec "$vmid" -- \
          systemctl --failed --type=service --no-legend --no-pager --plain \
          </dev/null 2>/dev/null
      )" || failed_units="__forge_systemctl_error__"

      if [[ "$baseline_active" == true && -z "$failed_units" ]]; then
        post_backup_ready=true
        break
      fi
    fi

    sleep 2
  done

  if [[ "$post_backup_ready" != true ]]; then
    if [[ "$service_manager" == systemd ]]; then
      inactive_services=()

      for service in "${baseline_services[@]}"; do
        if ! pct exec "$vmid" -- systemctl is-active --quiet "$service" </dev/null 2>/dev/null; then
          inactive_services+=("$service")
        fi
      done

      failed_units="$(
        pct exec "$vmid" -- \
          systemctl --failed --type=service --no-legend --no-pager --plain \
          </dev/null 2>/dev/null
      )" || failed_units="could not query failed systemd services"

      if (( ${#inactive_services[@]} > 0 )); then
        printf 'ERROR: LXC %s did not recover its pre-backup active services: %s\n' \
          "$vmid" "${inactive_services[*]}" >&2
      fi

      if [[ -n "$failed_units" ]]; then
        printf 'ERROR: LXC %s has failed systemd services after backup:\n%s\n' \
          "$vmid" "$failed_units" >&2
      fi
    else
      printf 'ERROR: LXC %s did not return to a ready running state after backup\n' \
        "$vmid" >&2
    fi

    exit 1
  fi
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
printf 'backup=success vmid=%s storage=%s volume=%s upid=%s\n' \
  "$vmid" "$storage" "$backup_volume" "$upid"
