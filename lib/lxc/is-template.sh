#!/bin/bash

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: is-template.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
environment_script="$script_dir/get-environment.sh"
[[ -r "$environment_script" ]] || fail "LXC environment helper is not readable: $environment_script"
bash "$environment_script" >/dev/null || fail "LXC environment check failed"

config_file="/etc/pve/lxc/${vmid}.conf"
[[ -f "$config_file" ]] || fail "LXC $vmid does not exist"

if grep -Eq '^template:[[:space:]]*1([[:space:]]|$)' "$config_file"; then
  printf 'true'
else
  printf 'false'
fi
