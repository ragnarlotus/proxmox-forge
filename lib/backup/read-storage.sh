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

for command_name in pvesh hostname python3; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is not available: $command_name"
done

node="$(hostname -s)" || fail "could not determine local Proxmox node name"
[[ -n "$node" ]] || fail "local Proxmox node name is empty"

jobs_json="$(pvesh get /cluster/backup --output-format json)" || \
  fail "could not read Proxmox backup jobs through pvesh"

storages="$(
  NODE="$node" python3 -c '
import json
import os
import sys

node = os.environ["NODE"]
jobs = json.load(sys.stdin)

if not isinstance(jobs, list):
    raise SystemExit("backup API response is not an array")

storages = set()

for job in jobs:
    if not isinstance(job, dict):
        continue

    if "enabled" in job and job["enabled"] in (0, False, None, "", "0"):
        continue

    job_node = job.get("node")
    if job_node is not None and str(job_node) != node:
        continue

    storage = job.get("storage")
    if storage is None or isinstance(storage, (dict, list)):
        continue

    storage = str(storage)
    if storage:
        storages.add(storage)

for storage in sorted(storages):
    print(storage)
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
