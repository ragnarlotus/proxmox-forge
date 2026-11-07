#!/usr/bin/env python3
"""F228: read-only status/history views over retained authoritative Forge run logs."""

import argparse
import json
import re
import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "i18n"))
from translate import tr  # noqa: E402

from table import clean, fields, parse, summarize

RUN_ID = re.compile(r"[0-9]{8}T[0-9]{6}-[0-9]+")
FQDN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
EVENT = re.compile(
    r"^([0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+) "
    r"level=(?:INFO|WARN|ERROR) event=(run_start|run_end|recovery_artifact|"
    r"backup_artifact|reboot_status|target_update_start|target_update_end|"
    r"stage_start|stage_end)(?: |$)"
)
GLOBAL = re.compile(r"^result_global status=(SUCCESS|PARTIAL|FAILED) ")


def event_fields(line):
    """Decode the logger's shell-escaped tokens as data, never execute them."""
    match = EVENT.match(line)
    if not match:
        return None
    try:
        words = shlex.split(line.rstrip("\n"))
    except ValueError as exc:
        raise ValueError("malformed structured event") from exc
    values = {}
    for token in words[1:]:
        if "=" in token:
            key, value = token.split("=", 1)
            if key in values:
                raise ValueError("duplicate structured event field")
            values[key] = value
    return match.group(1), values


def parse_global(line):
    if not GLOBAL.match(line):
        raise ValueError("malformed global result")
    values = {}
    for token in line.rstrip("\n").split()[1:]:
        if "=" not in token:
            raise ValueError("malformed global result field")
        key, value = token.split("=", 1)
        if key in values:
            raise ValueError("duplicate global result field")
        values[key] = value
    expected = ("targets", "selected", "attempted", "succeeded",
                "failed", "skipped", "not_run")
    if any(not values.get(key, "").isdigit() for key in expected):
        raise ValueError("invalid global result count")
    return {"status": values["status"], **{key: int(values[key]) for key in expected}}


def number_or_none(value):
    return int(value) if value is not None and value.isdigit() else None


def optional(value):
    return None if value in (None, "", "-") else clean(value)


def read_run(path):
    """Only recorded data is shown; absent details are never reconstructed."""
    summary = {
        "run_id": path.stem,
        "started_at": None,
        "finished_at": None,
        "duration_seconds": None,
        "command": None,
        "status": "UNKNOWN",
        "complete": False,
        "exit_code": None,
        "totals": None,
        "targets": [],
        "log_path": str(path),
    }
    rows = []
    backups = {}
    reboots = {}
    target_durations = {}
    target_stages = {}
    active_target = None
    active_stage = None
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if line.startswith("result_target "):
                rows.append(parse(line))
                continue
            if line.startswith("result_global "):
                if summary["totals"] is not None:
                    raise ValueError("duplicate global result")
                summary["totals"] = parse_global(line)
                summary["status"] = summary["totals"]["status"]
                continue
            decoded = event_fields(line)
            if decoded is None:
                continue
            when, value = decoded
            kind = value.get("event")
            if kind == "run_start":
                if summary["started_at"] is not None:
                    raise ValueError("duplicate run start")
                if value.get("run_id") != path.stem:
                    raise ValueError("run start identifier mismatch")
                summary["started_at"] = when
                summary["command"] = optional(value.get("command"))
            elif kind == "run_end":
                if summary["complete"]:
                    raise ValueError("duplicate run end")
                if value.get("run_id") != path.stem:
                    raise ValueError("run end identifier mismatch")
                code = number_or_none(value.get("exit_code"))
                if code is None:
                    raise ValueError("invalid run exit code")
                summary["exit_code"] = code
                summary["finished_at"] = when
                summary["duration_seconds"] = number_or_none(value.get("duration_seconds"))
                summary["complete"] = True
            elif kind == "target_update_start":
                # Target stages are serialized by the CLI. Stage events do not
                # carry a VMID, so associate them only with the active target.
                vmid = value.get("vmid", "")
                if value.get("type") == "host":
                    active_target = ("host", "HOST")
                elif vmid.isdigit():
                    active_target = ("lxc", vmid)
                else:
                    active_target = None
                active_stage = None
            elif kind == "stage_start":
                stage = value.get("stage", "")
                if active_target and re.fullmatch(r"[a-z][a-z0-9_-]*", stage):
                    active_stage = stage
                else:
                    active_stage = None
            elif kind == "stage_end":
                stage = value.get("stage", "")
                if (active_target and active_stage == stage
                        and value.get("status") in ("success", "failed", "logging_failed")):
                    target_stages.setdefault(active_target, []).append({
                        "name": stage,
                        "status": value["status"],
                        "duration_seconds": number_or_none(value.get("duration_seconds")),
                    })
                active_stage = None
            elif kind == "target_update_end":
                vmid = value.get("vmid", "")
                key = (("host", "HOST") if value.get("type") == "host"
                       else ("lxc", vmid) if vmid.isdigit() else None)
                if key is not None and value.get("status") in ("success", "failed"):
                    target_durations[key] = number_or_none(value.get("duration_seconds"))
                if key == active_target:
                    active_target = None
                    active_stage = None
            elif kind == "recovery_artifact":
                vmid = value.get("vmid", "")
                if vmid.isdigit() and value.get("backup"):
                    backups[("lxc", vmid)] = clean(value["backup"])
            elif kind == "backup_artifact":
                if value.get("type") == "host" and value.get("backup"):
                    backups[("host", "HOST")] = clean(value["backup"])
            elif kind == "reboot_status":
                vmid = value.get("vmid")
                target = ("lxc", vmid) if vmid and vmid.isdigit() else ("host", "HOST")
                state = value.get("reboot_required")
                if state in ("yes", "no", "unknown"):
                    reboots[target] = state

    if summary["totals"] is not None:
        totals = summary["totals"]
        if totals["targets"] != len(rows):
            raise ValueError("global target count differs from recorded rows")
        actual = {
            "succeeded": sum(r["status"] == "OK" for r in rows),
            "failed": sum(r["status"] == "ERROR" for r in rows),
            "skipped": sum(r["status"] == "SKIPPED" for r in rows),
            "not_run": sum(r["status"] == "NOT_RUN" for r in rows),
            "selected": sum(r["selected"] == "true" for r in rows),
            "attempted": sum(r["attempted"] == "true" for r in rows),
        }
        if any(totals[key] != count for key, count in actual.items()):
            raise ValueError("global result differs from authoritative target records")
        if totals["status"] != summarize(rows)[3]:
            raise ValueError("global status differs from authoritative target records")

    for row in rows:
        key = row["type"], row["vmid"]
        attempted = row["attempted"] == "true"
        summary["targets"].append({
            "type": row["type"],
            "vmid": row["vmid"],
            "name": clean(row["name"]),
            "selected": row["selected"] == "true",
            "attempted": attempted,
            "status": row["status"],
            "reason": row["reason"],
            "exit_code": number_or_none(row.get("exit_code")),
            "apt_upgraded": number_or_none(row.get("apt_upgraded")),
            "app_before": optional(row.get("app_before")),
            "app_after": optional(row.get("app_after")),
            "app_repository": optional(row.get("app_repository")),
            "failed_stage": optional(row.get("failed_stage")),
            "recovery": optional(row.get("recovery")),
            "result_detail": fields(row)[5],
            "reboot_required": reboots.get(key) if attempted else None,
            "backup": backups.get(key) if attempted else None,
            "duration_seconds": target_durations.get(key) if attempted else None,
            "stages": target_stages.get(key, []) if attempted else [],
        })
    return summary


def available_runs(root, fqdn):
    if not root.is_absolute() or not FQDN.fullmatch(fqdn):
        raise ValueError("invalid log directory or Proxmox hostname")
    folder = root / fqdn / "runs"
    if not folder.exists():
        return []
    if not folder.is_dir():
        raise ValueError("run log path is not a directory")
    return sorted(
        (path for path in folder.iterdir()
         if RUN_ID.fullmatch(path.stem) and path.suffix == ".log"
         and path.is_file() and not path.is_symlink()),
        key=lambda path: path.stem, reverse=True,
    )


def duration_text(seconds):
    if seconds is None:
        return tr("history.unknown")
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours} h {minutes} m {seconds} s"
    if minutes:
        return f"{minutes} m {seconds} s"
    return f"{seconds} s"


def show_detail(run):
    print(tr("history.title"))
    for name, value in (
        (tr("history.run"), run["run_id"]), (tr("history.started"), run["started_at"]),
        (tr("history.finished"), run["finished_at"]),
        (tr("history.duration"), duration_text(run["duration_seconds"])),
        (tr("history.command"), run["command"]),
        (tr("history.result"), run["status"]), (tr("history.exit"), run["exit_code"]),
    ):
        print(f"  {name}: {clean(value) if value is not None else tr('history.unknown')}")
    if not run["complete"]:
        print(tr("history.execution_incomplete"))
    totals = run["totals"]
    if totals:
        print(
            f"  {tr('history.targets')}: {totals['targets']} | OK: {totals['succeeded']} | "
            f"ERROR: {totals['failed']} | SKIPPED: {totals['skipped']} | "
            f"NOT_RUN: {totals['not_run']}"
        )
    else:
        print(tr("history.totals_unknown"))
    for target in run["targets"]:
        print(f"  {target['vmid']} ({target['name']}): {target['status']}")
        print(f"    {tr('history.detail')}: {target['result_detail']}")
        if target["attempted"]:
            print(f"    {tr('history.duration')}: {duration_text(target['duration_seconds'])}")
            for stage in target["stages"]:
                print(f"    {tr('history.stage')} {stage['name']}: "
                      f"{duration_text(stage['duration_seconds'])} ({stage['status']})")
            print(f"    {tr('history.apt')}: {target['apt_upgraded'] if target['apt_upgraded'] is not None else tr('history.unknown')}")
            before, after = target["app_before"], target["app_after"]
            if before or after:
                print(f"    {tr('history.application')}: {before or tr('history.unknown')} -> {after or tr('history.unknown')}")
            print(f"    {tr('history.reboot')}: {target['reboot_required'] or tr('history.unknown')}")
            if target["failed_stage"]:
                print(f"    {tr('history.failed_stage')}: {target['failed_stage']}")
            if target["recovery"]:
                print(f"    {tr('history.recovery')}: {target['recovery']}")
            if target["backup"]:
                print(f"    {tr('history.backup')}: {target['backup']}")
    if not run["targets"]:
        print(tr("history.no_targets"))
    print(f"  {tr('history.log')}: {run['log_path']}")


def show_history(runs):
    if not runs:
        print(tr("history.no_runs"))
        return
    print(tr("history.list"))
    for run in runs:
        totals = run["totals"]
        counts = (
            f"OK={totals['succeeded']} ERROR={totals['failed']} "
            f"SKIPPED={totals['skipped']} NOT_RUN={totals['not_run']}"
            if totals else tr("history.totals_unknown_short")
        )
        completion = "" if run["complete"] else " [INCOMPLETE]"
        print(f"  {run['run_id']}  {run['status']}{completion}  "
              f"duration={duration_text(run['duration_seconds'])}  {counts}")


def main():
    parser = argparse.ArgumentParser(description="Read retained Forge update logs")
    parser.add_argument("action", choices=("status", "history"))
    parser.add_argument("log_dir")
    parser.add_argument("fqdn")
    parser.add_argument("run_id", nargs="?")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if args.action == "status" and args.run_id:
        parser.error("status accepts no run ID")
    if args.run_id and not RUN_ID.fullmatch(args.run_id):
        parser.error("invalid run ID")
    paths = available_runs(Path(args.log_dir), args.fqdn)
    if args.run_id:
        paths = [p for p in paths if p.stem == args.run_id]
        if not paths:
            raise ValueError(f"run ID is not retained: {args.run_id}")
    if args.action == "status":
        result = read_run(paths[0]) if paths else None
    elif args.run_id:
        result = read_run(paths[0])
    else:
        result = [read_run(path) for path in paths]
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    elif result is None:
        print("No retained Forge update executions found.")
    elif isinstance(result, list):
        show_history(result)
    else:
        show_detail(result)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as exc:
        print(f"ERROR: cannot read Forge history: {exc}", file=sys.stderr)
        sys.exit(2)
