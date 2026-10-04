#!/bin/bash
# Description: Reads one Proxmox task UPID and returns pending, success, or failure based on the authoritative task status and exitstatus.

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

[[ $# -eq 1 ]] || fail "usage: result.sh UPID"
upid="$1"

command -v pvesh >/dev/null 2>&1 || fail "pvesh is not available"
command -v perl >/dev/null 2>&1 || fail "perl is not available"

case "$upid" in
  UPID:*:*) ;;
  *) fail "invalid Proxmox UPID" ;;
esac

node="${upid#UPID:}"
node="${node%%:*}"
[[ -n "$node" ]] || fail "could not determine node from UPID"

status_json="$(pvesh get "/nodes/$node/tasks/$upid/status" --output-format json)" || \
  fail "could not read Proxmox task status"

UPID="$upid" NODE="$node" perl -MJSON::PP -e '
  use strict;
  use warnings;

  my $upid = $ENV{UPID};
  my $node = $ENV{NODE};
  my $task = decode_json(do { local $/; <STDIN> });

  die "task status response is not an object\n" unless ref($task) eq "HASH";

  my $status = defined($task->{status}) ? "$task->{status}" : "unknown";
  my $exitstatus = defined($task->{exitstatus}) ? "$task->{exitstatus}" : "";

  if ($status ne "stopped") {
    print "task=pending node=$node upid=$upid status=$status\n";
    exit 2;
  }

  if ($exitstatus eq "OK") {
    print "task=success node=$node upid=$upid status=$status exitstatus=OK\n";
    exit 0;
  }

  $exitstatus = "unknown" if $exitstatus eq "";
  print STDERR "task=failure node=$node upid=$upid status=$status exitstatus=$exitstatus\n";
  exit 1;
' <<<"$status_json"
