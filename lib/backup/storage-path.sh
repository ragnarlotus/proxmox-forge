#!/bin/bash
# Description: Resolves the local absolute filesystem path of one configured Proxmox backup storage from the live storage configuration.

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

[[ $# -eq 1 ]] || fail "usage: storage-path.sh STORAGE"
storage="$1"
[[ "$storage" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid storage identifier '$storage'"

command -v pvesm >/dev/null 2>&1 || fail "pvesm is not available"
command -v perl >/dev/null 2>&1 || fail "perl is not available"
[[ -r /etc/pve/storage.cfg ]] || fail "/etc/pve/storage.cfg is not readable"

pvesm status --storage "$storage" >/dev/null 2>&1 || fail "Proxmox storage is not currently available: $storage"

record="$(
  STORAGE="$storage" perl -e '
    use strict;
    use warnings;

    my $wanted = $ENV{STORAGE};
    open my $fh, "<", "/etc/pve/storage.cfg" or die "cannot read storage.cfg: $!\n";

    my ($active, $path, $content);
    while (my $line = <$fh>) {
      if ($line =~ /^\s*([A-Za-z0-9_-]+):\s+([^\s#]+)\s*$/) {
        last if $active;
        $active = ($2 eq $wanted) ? 1 : 0;
        next;
      }

      next unless $active;
      $path = $1 if $line =~ /^\s+path\s+(.+?)\s*$/;
      $content = $1 if $line =~ /^\s+content\s+(.+?)\s*$/;
    }

    die "storage $wanted has no explicit local path\n" unless defined($path) && length($path);
    die "storage $wanted does not allow backup content\n"
      unless defined($content) && grep { $_ eq "backup" } split /,/, $content;

    print "path=$path\ncontent=$content\n";
  '
)" || fail "could not resolve filesystem path for Proxmox storage $storage"

path="$(printf '%s\n' "$record" | sed -n 's/^path=//p' | head -n 1)"
[[ "$path" == /* ]] || fail "storage $storage returned a non-absolute path"
[[ -d "$path" ]] || fail "storage path does not exist: $path"

printf '%s\n' "$path"
