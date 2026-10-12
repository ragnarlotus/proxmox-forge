#!/bin/bash
# Description: Reports recovery-policy conflicts for the exact selected LXC VMIDs, without modifying Proxmox.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run it through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

(( $# > 0 )) || exit 0

node="$(hostname -s)" || exit 1
jobs_json="$(pvesh get /cluster/backup --output-format json)" || {
  printf 'ERROR: cannot read Proxmox backup jobs\n' >&2
  exit 1
}

FORGE_JOBS_JSON="$jobs_json" FORGE_NODE="$node" python3 - "$@" <<'PY'
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
ok = True
for vmid in sys.argv[1:]:
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
            raise ValueError("Proxmox does not support persistent snapshots for this LXC")

    except (ValueError, KeyError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        ok = fail(vmid, exc) and ok

if not ok:
    sys.exit(1)
PY
