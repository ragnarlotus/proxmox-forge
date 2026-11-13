#!/bin/bash
# Description: Creates one synchronous LXC backup using the applicable Proxmox backup policy and returns the exact created recovery volume.

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

list_backup_volumes() {
  local storage="$1"
  local output result line volume

  output="$(LC_ALL=C pvesm list "$storage" --vmid "$vmid" --content backup 2>&1)"
  result=$?

  if (( result != 0 )); then
    printf '%s\n' "$output" >&2
    return "$result"
  fi

  while IFS= read -r line; do
    read -r volume _ <<<"$line"

    case "${volume:-}" in
      "$storage":*) printf '%s\n' "$volume" ;;
    esac
  done <<<"$output" | LC_ALL=C sort -u
}

[[ $# -eq 1 ]] || fail "usage: create.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

for command_name in vzdump pvesh pvesm python3 hostname; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is not available"
done

[[ -f "/etc/pve/lxc/${vmid}.conf" ]] || fail "LXC $vmid does not exist on this Proxmox host"

node="$(hostname -s)" || fail "could not determine local Proxmox node name"
[[ -n "$node" ]] || fail "local Proxmox node name is empty"

jobs_json="$(pvesh get /cluster/backup --output-format json)" || \
  fail "could not read Proxmox backup jobs through pvesh"

usage_text="$(vzdump help 2>&1)" || fail "could not read vzdump CLI usage"

mapfile -d '' -t fields < <(
  JOBS_JSON="$jobs_json" USAGE_TEXT="$usage_text" VMID="$vmid" NODE="$node" \
  python3 -c '
import json
import os
import re
import sys

vmid = os.environ["VMID"]
node = os.environ["NODE"]
usage = os.environ["USAGE_TEXT"]
jobs = json.loads(os.environ["JOBS_JSON"])

if not isinstance(jobs, list):
    raise SystemExit("backup API response is not an array")

def is_false(value):
    return value is None or value is False or value == 0 or value == "" or value == "0"

def contains_vmid(value, wanted):
    if value is None:
        return False
    return wanted in [item for item in re.split(r"[,\s]+", str(value)) if item]

matches = []

for job in jobs:
    if not isinstance(job, dict):
        continue

    if "enabled" in job and is_false(job["enabled"]):
        continue

    job_node = job.get("node")
    if job_node is not None and str(job_node) != node:
        continue

    applies = False

    if job.get("vmid") is not None:
        applies = contains_vmid(job["vmid"], vmid)
    elif not is_false(job.get("all")):
        applies = not contains_vmid(job.get("exclude"), vmid)

    if applies:
        matches.append(job)

if not matches:
    raise SystemExit(f"no enabled Proxmox backup job applies to LXC {vmid}")

if len(matches) > 1:
    raise SystemExit(
        f"multiple enabled Proxmox backup jobs apply to LXC {vmid}; "
        "Forge will not choose implicitly"
    )

job = matches[0]
accepted = set(re.findall(r"^\s*--([a-z0-9][a-z0-9-]*)\b", usage, re.MULTILINE))

if not accepted:
    raise SystemExit("could not discover vzdump CLI parameters")

skip = {
    "all",
    "enabled",
    "exclude",
    "id",
    "next-run",
    "node",
    "repeat-missed",
    "schedule",
    "type",
    "vmid",
}

def scalar_value(key, value):
    if value is None:
        return None
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, (str, int, float)):
        return str(value)
    if isinstance(value, dict):
        parts = []
        for subkey in sorted(value):
            subvalue = value[subkey]
            if isinstance(subvalue, (dict, list)):
                raise SystemExit(f"unsupported nested value in backup option {key}")
            if subvalue is None:
                text = ""
            elif isinstance(subvalue, bool):
                text = "1" if subvalue else "0"
            else:
                text = str(subvalue)
            parts.append(f"{subkey}={text}")
        return ",".join(parts)
    raise SystemExit(f"unsupported Proxmox backup option shape for {key}")

params = []

if job.get("id") is not None and "job-id" in accepted:
    params.append(("job-id", str(job["id"])))

for key in sorted(job):
    if key in skip or key not in accepted:
        continue

    # Forge currently creates LXC backups; Proxmox documents fleecing as VM-only.
    if key == "fleecing":
        continue

    value = scalar_value(key, job[key])
    if value is not None:
        params.append((key, value))

storages = [value for name, value in params if name == "storage"]

if len(storages) != 1:
    raise SystemExit("backup plan must contain exactly one storage parameter")

if not storages[0]:
    raise SystemExit("backup storage value is missing")

output = [storages[0]]
for name, value in params:
    output.extend((f"--{name}", value))

sys.stdout.buffer.write(b"\0".join(item.encode() for item in output) + b"\0")
'
)

(( ${#fields[@]} >= 3 )) || fail "backup policy returned no execution parameters"
(( (${#fields[@]} - 1) % 2 == 0 )) || fail "backup policy returned malformed execution parameters"

storage="${fields[0]}"
command=(vzdump "$vmid")

for ((i = 1; i < ${#fields[@]}; i += 2)); do
  command+=("${fields[i]}" "${fields[i + 1]}")
done

before_backups="$(list_backup_volumes "$storage")" || \
  fail "could not list existing backups for LXC $vmid on storage $storage"

# Capture the live vzdump stream while retaining its reported archive path.
# The global Proxmox lock can delay this command while other jobs create
# backups, so a before/after inventory diff is not sufficient.
vzdump_output="$(mktemp)" || fail "cannot create temporary vzdump output capture"
trap 'rm -f -- "$vzdump_output"' EXIT
"${command[@]}" 2>&1 | tee "$vzdump_output"
capture_results=("${PIPESTATUS[@]}")
create_result="${capture_results[0]}"
(( capture_results[1] == 0 )) || fail "could not capture vzdump output for recovery identification"

if (( create_result != 0 )); then
  printf 'ERROR: Proxmox vzdump backup failed for LXC %s (exit code: %s)\n' \
    "$vmid" "$create_result" >&2
  exit "$create_result"
fi

after_backups="$(list_backup_volumes "$storage")" || \
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

# File-based vzdump backups report the actual archive path. Match it to
# a newly listed pvesm volume rather than picking the newest volume, since a
# scheduled job may have completed while this vzdump waited for the lock.
mapfile -t created_paths < <(
  LC_ALL=C sed -nE "s/^INFO: creating vzdump archive '(.+)'$/\\1/p" "$vzdump_output"
)
if (( ${#created_paths[@]} > 1 )); then
  fail "vzdump reported multiple created archives; recovery volume is ambiguous"
fi

backup_volume=""
if (( ${#created_paths[@]} == 1 )); then
  matches=()
  for volume in "${new_backups[@]}"; do
    volume_path="$(pvesm path "$volume")" ||
      fail "could not resolve created backup volume $volume"
    [[ "$volume_path" == "${created_paths[0]}" ]] && matches+=("$volume")
  done
  if (( ${#matches[@]} != 1 )); then
    fail "vzdump archive does not uniquely match a newly listed backup (new volumes: ${#new_backups[@]}, matches: ${#matches[@]})"
  fi
  backup_volume="${matches[0]}"
elif (( ${#new_backups[@]} == 1 )); then
  # Non-file backup providers may not report a local archive path.
  backup_volume="${new_backups[0]}"
else
  fail "backup task succeeded but the exact created recovery volume could not be identified (new volumes: ${#new_backups[@]})"
fi

printf 'backup=success vmid=%s storage=%s volume=%s\n' \
  "$vmid" "$storage" "$backup_volume"
