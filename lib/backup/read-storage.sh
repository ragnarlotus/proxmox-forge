#!/bin/bash
# Description: Reads enabled Proxmox backup jobs for the local node and returns the single backup storage they use; it fails when the destination is ambiguous.

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

[[ $# -eq 0 ]] || fail "read-storage.sh does not accept arguments"

for command_name in pvesh hostname perl; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is not available: $command_name"
done

node="$(hostname -s)" || fail "could not determine local Proxmox node name"
[[ -n "$node" ]] || fail "local Proxmox node name is empty"

jobs_json="$(pvesh get /cluster/backup --output-format json)" || \
  fail "could not read Proxmox backup jobs through pvesh"

storages="$(
  NODE="$node" perl -MJSON::PP -e '
    use strict;
    use warnings;

    my $node = $ENV{NODE};
    my $jobs = decode_json(do { local $/; <STDIN> });
    die "backup API response is not an array\n" unless ref($jobs) eq "ARRAY";

    my %storages;
    for my $job (@$jobs) {
      next unless ref($job) eq "HASH";
      next if exists($job->{enabled}) && !$job->{enabled};
      next if defined($job->{node}) && $job->{node} ne $node;

      my $storage = $job->{storage};
      next unless defined($storage) && !ref($storage) && length($storage);
      $storages{$storage} = 1;
    }

    print "$_\n" for sort keys %storages;
  ' <<<"$jobs_json"
)" || fail "could not evaluate Proxmox backup storages for node $node"

mapfile -t storage_list <<<"$storages"
filtered=()
for storage in "${storage_list[@]}"; do
  [[ -n "$storage" ]] && filtered+=("$storage")
done

case "${#filtered[@]}" in
  0) fail "no enabled Proxmox backup storage applies to node $node" ;;
  1) printf '%s\n' "${filtered[0]}" ;;
  *) fail "multiple Proxmox backup storages apply to node $node; Forge will not choose implicitly: ${filtered[*]}" ;;
esac
