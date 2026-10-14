#!/bin/bash
# Description: Validates backup-only LXC recovery safety for the selected VMIDs without modifying Proxmox.

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
  "${CONFIG[CREATE_BACKUP_BEFORE_LXC_UPDATE]}" \
  "${CONFIG[ROLLBACK_ON_FAILURE]}" "$@" <<'PY'
import json
import os
import re
import subprocess
import sys


def fail(vmid, reason):
    print(f"CONFLICT: LXC {vmid}: {reason}", file=sys.stderr)
    return False


def contains(value, wanted):
    return value is not None and wanted in re.split(r"[,\s]+", str(value))


def is_false(value):
    return value is None or value is False or value == 0 or value == "" or value == "0"


try:
    jobs = json.loads(os.environ["FORGE_JOBS_JSON"])
    if not isinstance(jobs, list):
        raise ValueError("backup jobs response is not an array")
except (ValueError, KeyError) as exc:
    sys.exit(f"ERROR: invalid Proxmox backup job data: {exc}")

node = os.environ["FORGE_NODE"]
create_backup = sys.argv[1] == "true"
automatic_recovery = sys.argv[2] == "true"
ok = True

for vmid in sys.argv[3:]:
    if not vmid.isdigit():
        ok = fail(vmid, "invalid VMID") and ok
        continue

    try:
        if not create_backup:
            raise ValueError("backup-only updates require CREATE_BACKUP_BEFORE_LXC_UPDATE=true")

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

        if not automatic_recovery:
            continue

        # pct restore --force could destroy older persistent snapshots. Do not
        # remove them automatically or start an update that cannot be recovered.
        snaps = subprocess.run(
            ["pvesh", "get", f"/nodes/{node}/lxc/{vmid}/snapshot",
             "--output-format", "json"],
            capture_output=True, text=True, check=True,
        )
        snapshots = json.loads(snaps.stdout)
        if not isinstance(snapshots, list) or any(
            not isinstance(s, dict) or s.get("name") != "current"
            for s in snapshots
        ):
            raise ValueError(
                "automatic backup restore would destroy existing persistent snapshots; "
                "review/remove them manually before updating"
            )

        config = subprocess.run(
            ["pct", "config", vmid], capture_output=True, text=True, check=True,
        )
        rootfs = [line.split(":", 1)[1].strip()
                  for line in config.stdout.splitlines()
                  if line.startswith("rootfs:")]
        if len(rootfs) != 1 or not re.match(r"^[a-zA-Z0-9_-]+:[^,\s]+", rootfs[0]):
            raise ValueError("backup recovery requires a storage-backed rootfs")

    except (ValueError, KeyError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        ok = fail(vmid, exc) and ok

if not ok:
    sys.exit(1)
PY
