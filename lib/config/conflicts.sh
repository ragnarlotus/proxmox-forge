#!/bin/bash
# Description: Reports recovery-policy conflicts for the exact selected LXC VMIDs, without modifying Proxmox.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run it through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

(( $# > 0 )) || exit 0

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=/dev/null
source "$script_dir/get.sh" || exit 1
config_get || exit 1

node="$(hostname -s)" || exit 1
jobs_json="$(pvesh get /cluster/backup --output-format json)" || {
  printf 'ERROR: cannot read Proxmox backup jobs\n' >&2
  exit 1
}

FORGE_JOBS_JSON="$jobs_json" FORGE_NODE="$node" python3 - \
  "${CONFIG[BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE]}" \
  "${CONFIG[CREATE_BACKUP_BEFORE_LXC_UPDATE]}" "$@" <<'PY'
import json
import os
import re
import subprocess
import sys

def fail(vmid, reason):
    print(f"CONFLICT: LXC {vmid}: {reason}", file=sys.stderr)
    return False

def contains(value, wanted):
    if value is None:
        return False
    return wanted in re.split(r"[,\s]+", str(value))

def is_false(value):
    return value is None or value is False or value == 0 or value == "" or value == "0"

try:
    jobs = json.loads(os.environ["FORGE_JOBS_JSON"])
    if not isinstance(jobs, list):
        raise ValueError("backup jobs response is not an array")
except (ValueError, KeyError) as exc:
    sys.exit(f"ERROR: invalid Proxmox backup job data: {exc}")

node = os.environ["FORGE_NODE"]
allow_backup = sys.argv[1] == "true"
create_backup = sys.argv[2] == "true"
ok = True
fallback = []
for vmid in sys.argv[3:]:
    if not vmid.isdigit():
        ok = fail(vmid, "invalid VMID") and ok
        continue

    try:
        matching = []
        for job in jobs:
            if not isinstance(job, dict):
                continue
            if "enabled" in job and is_false(job["enabled"]):
                continue
            if job.get("node") is not None and str(job["node"]) != node:
                continue
            if job.get("vmid") is not None:
                applies = contains(job["vmid"], vmid)
            else:
                applies = not is_false(job.get("all")) and not contains(job.get("exclude"), vmid)
            if applies:
                matching.append(job)

        if len(matching) != 1:
            raise ValueError(f"expected one applicable enabled backup job, found {len(matching)}")
        job = matching[0]
        if not isinstance(job.get("storage"), str) or not job["storage"]:
            raise ValueError("backup job has no storage")

        retention = job.get("prune-backups")
        if isinstance(retention, dict):
            keep_last = str(retention.get("keep-last", ""))
        elif isinstance(retention, str):
            entries = [x.strip().split("=", 1) for x in retention.split(",")]
            if any(len(e) != 2 for e in entries):
                raise ValueError("malformed prune-backups policy")
            keep_last = dict(entries).get("keep-last", "")
        else:
            raise ValueError("backup job has no explicit prune-backups policy")
        if not re.fullmatch(r"[1-9][0-9]*", keep_last):
            raise ValueError("backup job must set keep-last greater than zero")

        result = subprocess.run(
            ["pvesh", "get", f"/nodes/{node}/lxc/{vmid}/feature",
             "--feature", "snapshot", "--output-format", "json"],
            capture_output=True, text=True, check=True,
        )
        feature = json.loads(result.stdout).get("hasFeature")
        if type(feature) is not int or feature not in (0, 1):
            raise ValueError("invalid snapshot feature response")
        if feature == 0:
            if not allow_backup:
                raise ValueError(
                    "persistent snapshots unsupported; BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=false"
                )
            if not create_backup:
                raise ValueError("backup fallback requires CREATE_BACKUP_BEFORE_LXC_UPDATE=true")

            snap_result = subprocess.run(
                ["pvesh", "get", f"/nodes/{node}/lxc/{vmid}/snapshot",
                 "--output-format", "json"],
                capture_output=True, text=True, check=True,
            )
            snapshots = json.loads(snap_result.stdout)
            if not isinstance(snapshots, list) or any(
                not isinstance(s, dict) or s.get("name") != "current"
                for s in snapshots
            ):
                raise ValueError("backup restore would destroy existing persistent snapshots")

            config_result = subprocess.run(
                ["pct", "config", vmid], capture_output=True, text=True, check=True,
            )
            rootfs = [line.split(":", 1)[1].strip()
                      for line in config_result.stdout.splitlines()
                      if line.startswith("rootfs:")]
            if len(rootfs) != 1 or not re.match(r"^[a-zA-Z0-9_-]+:[^,\s]+", rootfs[0]):
                raise ValueError("backup recovery requires a storage-backed rootfs")

            fallback.append(vmid)

    except (ValueError, KeyError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        ok = fail(vmid, exc) and ok

if not ok:
    sys.exit(1)
for vmid in fallback:
    print(f"backup_fallback={vmid}")
PY
