#!/bin/bash
# Description: Executes one prepared synchronous vzdump backup for an LXC, verifies that a running guest returns to its pre-backup service baseline, and returns the exact created recovery volume.

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
command -v pct >/dev/null 2>&1 || fail "pct is not available"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
plan_script="$script_dir/prepare.sh"
list_script="$script_dir/list-volumes.sh"

for helper in "$plan_script" "$list_script"; do
  [[ -r "$helper" ]] || fail "required backup helper is not readable: $helper"
done

plan_json="$(bash "$plan_script" "$vmid")" || \
  fail "could not prepare Proxmox backup for LXC $vmid"

mapfile -d '' -t fields < <(
  PLAN_JSON="$plan_json" VMID="$vmid" perl -MJSON::PP -e '
    use strict;
    use warnings;

    my $plan = decode_json($ENV{PLAN_JSON});
    die "backup plan is not an object\n" unless ref($plan) eq "HASH";
    die "backup plan has no vmid\n" unless defined($plan->{vmid}) && !ref($plan->{vmid}) && length($plan->{vmid});
    die "backup plan vmid does not match target\n" unless "$plan->{vmid}" eq $ENV{VMID};
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

status_output="$(pct status "$vmid" 2>/dev/null)" || \
  fail "could not read pre-backup state for LXC $vmid"
pre_backup_state="${status_output#status: }"

service_manager="none"
baseline_services=()

if [[ "$pre_backup_state" == running ]]; then
  service_manager="$(pct exec "$vmid" -- sh -c '
    if command -v systemctl >/dev/null 2>&1; then
      printf "systemd"
    else
      printf "none"
    fi
  ' </dev/null)" || fail "LXC $vmid is running but not ready before backup"

  if [[ "$service_manager" == systemd ]]; then
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

"${command[@]}"
create_result=$?

if (( create_result != 0 )); then
  printf 'ERROR: Proxmox vzdump backup failed for LXC %s (exit code: %s)\n' \
    "$vmid" "$create_result" >&2
  exit "$create_result"
fi

if [[ "$pre_backup_state" == running ]]; then
  post_backup_ready=false
  failed_units=""
  inactive_services=()

  for ((attempt = 1; attempt <= 30; attempt++)); do
    status_output="$(pct status "$vmid" 2>/dev/null)" || status_output=""
    post_backup_state="${status_output#status: }"

    if [[ "$post_backup_state" == running ]]; then
      if [[ "$service_manager" != systemd ]]; then
        if pct exec "$vmid" -- sh -c 'exit 0' </dev/null; then
          post_backup_ready=true
          break
        fi
      else
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
printf 'backup=success vmid=%s storage=%s volume=%s\n' \
  "$vmid" "$storage" "$backup_volume"
