#!/bin/bash
# Description: Creates a persistent same-run LXC recovery snapshot, pruning only older Update_* snapshots using Proxmox's applicable backup-job keep-last policy.

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

[[ $# -eq 1 ]] || fail "usage: snapshot.sh VMID"
vmid="$1"
[[ "$vmid" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"

for command_name in pvesh pct python3 hostname date; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is not available"
done

node="$(hostname -s)" || fail "could not determine Proxmox node name"
[[ -n "$node" ]] || fail "Proxmox node name is empty"

jobs_json="$(pvesh get /cluster/backup --output-format json)" || fail "could not read Proxmox backup jobs"
snapshots_json="$(pvesh get "/nodes/$node/lxc/$vmid/snapshot" --output-format json)" || \
  fail "could not list existing snapshots for LXC $vmid"

snapshot_name="Update_$(date +%Y%m%d_%H%M%S)" || fail "could not generate snapshot name"

# Use the exact enabled Proxmox backup job applying to this VMID. Retention
# applies only to Update_* snapshots, never snapshots created manually.
prune_plan="$(
  JOBS_JSON="$jobs_json" SNAPSHOTS_JSON="$snapshots_json" \
  NODE="$node" VMID="$vmid" SNAPSHOT_NAME="$snapshot_name" \
  python3 -c '
import json
import os
import re

vmid = os.environ["VMID"]
node = os.environ["NODE"]
name = os.environ["SNAPSHOT_NAME"]
jobs = json.loads(os.environ["JOBS_JSON"])
snapshots = json.loads(os.environ["SNAPSHOTS_JSON"])

if not isinstance(jobs, list) or not isinstance(snapshots, list):
    raise SystemExit("invalid Proxmox backup-job or snapshot response")

def is_false(v):
    return v is None or v is False or v == 0 or v == "" or v == "0"

def contains_vmid(v):
    return v is not None and vmid in re.split(r"[,\s]+", str(v))

matches = []
for job in jobs:
    if not isinstance(job, dict):
        continue
    if "enabled" in job and is_false(job["enabled"]):
        continue
    if job.get("node") is not None and str(job["node"]) != node:
        continue
    if job.get("vmid") is not None:
        applies = contains_vmid(job["vmid"])
    else:
        applies = not is_false(job.get("all")) and not contains_vmid(job.get("exclude"))
    if applies:
        matches.append(job)

if len(matches) != 1:
    raise SystemExit(f"expected one applicable enabled Proxmox backup job for LXC {vmid}; got {len(matches)}")

retention = matches[0].get("prune-backups")
if isinstance(retention, dict):
    rules = {str(k): str(v) for k, v in retention.items()}
elif isinstance(retention, str):
    rules = {}
    for item in retention.split(","):
        pair = item.strip().split("=", 1)
        if len(pair) != 2:
            raise SystemExit(f"invalid Proxmox retention rule: {item}")
        rules[pair[0].strip()] = pair[1].strip()
else:
    raise SystemExit("Proxmox backup job has no explicit prune-backups policy")

keep_last = rules.get("keep-last", "")
if not re.fullmatch(r"[1-9][0-9]*", keep_last):
    raise SystemExit("Proxmox backup job must specify keep-last greater than zero for safe LXC snapshot retention")
limit = int(keep_last)

existing = []
names = set()
for entry in snapshots:
    if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
        raise SystemExit("invalid LXC snapshot record")
    snapname = entry["name"]
    names.add(snapname)
    if not snapname.startswith("Update_"):
        continue
    if not re.fullmatch(r"Update_[A-Za-z0-9_]+", snapname):
        raise SystemExit(f"unexpected Update_ snapshot name: {snapname}")
    timestamp = entry.get("snaptime")
    if not isinstance(timestamp, (int, float)):
        raise SystemExit(f"missing snapshot timestamp: {snapname}")
    existing.append((timestamp, snapname))

if name in names:
    raise SystemExit(f"recovery snapshot already exists: {name}")

existing.sort()
for _, old_name in existing[:max(0, len(existing) - limit + 1)]:
    print(old_name)
  '
)" || fail "could not determine safe Proxmox snapshot retention for LXC $vmid"

if [[ -n "$prune_plan" ]]; then
  while IFS= read -r old_snapshot; do
    [[ -n "$old_snapshot" ]] || continue
    pct delsnapshot "$vmid" "$old_snapshot" || fail "could not prune snapshot $old_snapshot from LXC $vmid"
    printf 'snapshot_prune=success vmid=%s name=%s\n' "$vmid" "$old_snapshot"
  done <<<"$prune_plan"
fi

pct snapshot "$vmid" "$snapshot_name" --description "Forge pre-update recovery" || \
  fail "could not create recovery snapshot $snapshot_name for LXC $vmid"

printf 'snapshot=success vmid=%s name=%s\n' "$vmid" "$snapshot_name"
