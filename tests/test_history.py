#!/usr/bin/env python3
"""F228: historical queries use retained authoritative data only, without mutations."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
HISTORY = ROOT / "lib/results/history.py"
FQDN = "bv.deulos.com"


def record(vmid, status="OK", type_="lxc", name="pihole",
           attempted=True, detail="OK", stage="-", recovery="-",
           apt="2", before="6.4.0", after="6.4.1"):
    values = {
        "type": type_, "vmid": vmid, "name": name,
        "selected": "true", "attempted": str(attempted).lower(),
        "status": status, "reason": "completed" if status == "OK" else "update_failed",
        "apt_upgraded": apt, "app_before": before, "app_after": after,
        "app_repository": "https://github.com/pi-hole/pi-hole" if type_ == "lxc" else "-",
        "failed_stage": stage, "recovery": recovery,
        "result_detail": quote(detail, safe=""),
    }
    if status == "ERROR":
        values["exit_code"] = "42"
    return "result_target " + " ".join(f"{k}={v}" for k, v in values.items())


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="forge-f228-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.logs = self.root / "log"
        self.runs = self.logs / FQDN / "runs"
        self.runs.mkdir(parents=True)
        self.older = "20261014T080000-23"
        self.newer = "20261015T090000-77"

    def store(self, run_id, body):
        path = self.runs / f"{run_id}.log"
        path.write_text(body, encoding="utf-8")
        return path

    def fixture(self, run_id=None, include_end=True, include_global=True):
        run_id = run_id or self.newer
        content = [
            f"2026-10-15T09:00:00+02:00 level=INFO event=run_start run_id={run_id} command=update\\ all",
            "2026-10-15T09:00:01+02:00 level=INFO event=backup_artifact type=host backup=/mnt/tomasz/backups/pve/host.tar.gz",
            "2026-10-15T09:00:02+02:00 level=INFO event=recovery_artifact vmid=101 backup=backups:vzdump-lxc-101-2026_10_15.tar.zst",
            "2026-10-15T09:00:03+02:00 level=INFO event=reboot_status type=host reboot_required=yes",
            "2026-10-15T09:00:04+02:00 level=INFO event=reboot_status vmid=101 reboot_required=no",
            record("HOST", type_="host", name=FQDN, before="-", after="-", apt="5"),
            record("101", status="ERROR", detail="ERROR: application_update (exit 42); recovery succeeded",
                   stage="application_update", recovery="success"),
        ]
        if include_global:
            content.append("result_global status=PARTIAL targets=2 selected=2 attempted=2 succeeded=1 failed=1 skipped=0 not_run=0")
        if include_end:
            content.append(f"2026-10-15T09:45:00+02:00 level=INFO event=run_end run_id={run_id} exit_code=1")
        return "\n".join(content) + "\n"

    def query(self, *args, log_dir=None):
        return subprocess.run(
            ["python3", str(HISTORY), *args[:1], str(log_dir or self.logs),
             FQDN, *args[1:]],
            capture_output=True, text=True, check=False,
        )

    def test_status_human_and_json_preserve_actual_failure_and_backup(self):
        path = self.store(self.newer, self.fixture())
        before = path.read_bytes()
        r = self.query("status", "--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        value = json.loads(r.stdout)
        self.assertEqual(value["status"], "PARTIAL")
        self.assertTrue(value["complete"])
        self.assertEqual(value["exit_code"], 1)
        self.assertEqual(value["command"], "update all")
        self.assertEqual(value["totals"]["failed"], 1)
        self.assertEqual(len(value["targets"]), 2)
        host, lxc = value["targets"]
        self.assertEqual(host["backup"], "/mnt/tomasz/backups/pve/host.tar.gz")
        self.assertEqual(host["reboot_required"], "yes")
        self.assertEqual(lxc["backup"], "backups:vzdump-lxc-101-2026_10_15.tar.zst")
        self.assertEqual(lxc["reboot_required"], "no")
        self.assertEqual(lxc["recovery"], "success")
        self.assertEqual(lxc["failed_stage"], "application_update")
        self.assertEqual(lxc["exit_code"], 42)
        self.assertEqual(lxc["app_before"], "6.4.0")
        self.assertEqual(lxc["app_after"], "6.4.1")
        self.assertIn("ERROR: application_update", lxc["result_detail"])
        self.assertEqual(path.read_bytes(), before)

        human = self.query("status")
        self.assertEqual(human.returncode, 0, human.stderr)
        self.assertIn("Result: PARTIAL", human.stdout)
        self.assertIn("Recovery: success", human.stdout)
        self.assertIn("Backup: backups:vzdump-lxc-101-", human.stdout)

    def test_history_is_newest_first_and_specific_run_is_queryable(self):
        self.store(self.older, self.fixture(self.older))
        self.store(self.newer, self.fixture())
        r = self.query("history", "--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual([x["run_id"] for x in json.loads(r.stdout)],
                         [self.newer, self.older])
        human = self.query("history")
        self.assertEqual(human.returncode, 0, human.stderr)
        self.assertLess(human.stdout.index(self.newer), human.stdout.index(self.older))
        detail = self.query("history", self.older, "--json")
        self.assertEqual(json.loads(detail.stdout)["run_id"], self.older)

    def test_incomplete_run_and_absent_authoritative_results_are_explicit(self):
        self.store(self.newer, self.fixture(include_end=False, include_global=False))
        r = self.query("status", "--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        value = json.loads(r.stdout)
        self.assertFalse(value["complete"])
        self.assertEqual(value["status"], "UNKNOWN")
        self.assertIsNone(value["totals"])
        self.assertIsNone(value["exit_code"])
        self.assertIn("INCOMPLETE", self.query("status").stdout)

    def test_failed_before_inventory_does_not_claim_success_or_target_results(self):
        self.store(self.newer, (
            f"2026-10-15T09:00:00+02:00 level=INFO event=run_start run_id={self.newer} command=host\\ update\n"
            f"2026-10-15T09:00:03+02:00 level=INFO event=run_end run_id={self.newer} exit_code=1\n"
        ))
        value = json.loads(self.query("status", "--json").stdout)
        self.assertTrue(value["complete"])
        self.assertEqual(value["status"], "UNKNOWN")
        self.assertEqual(value["exit_code"], 1)
        self.assertEqual(value["targets"], [])

    def test_missing_optional_artifacts_and_reboot_are_unknown(self):
        run = self.fixture()
        run = "\n".join(line for line in run.splitlines()
                        if "event=recovery_artifact" not in line
                        and "event=reboot_status" not in line
                        and "event=backup_artifact" not in line) + "\n"
        self.store(self.newer, run)
        value = json.loads(self.query("status", "--json").stdout)
        self.assertTrue(all(t["backup"] is None and t["reboot_required"] is None
                            for t in value["targets"]))

    def test_f146_measured_run_target_stage_durations(self):
        content = self.fixture().replace(
            f"run_id={self.newer} exit_code=1\n",
            f"run_id={self.newer} exit_code=1 duration_seconds=2700\n",
        )
        host = record("HOST", type_="host", name=FQDN,
                      before="-", after="-", apt="5")
        lxc = record("101", status="ERROR",
                     detail="ERROR: application_update (exit 42); recovery succeeded",
                     stage="application_update", recovery="success")
        content = content.replace(host + "\n", "\n".join([
            "2026-10-15T09:00:05+02:00 level=INFO event=target_update_start type=host hostname=bv.deulos.com",
            "2026-10-15T09:00:06+02:00 level=INFO event=stage_start stage=backup command=vzdump",
            "2026-10-15T09:01:46+02:00 level=INFO event=stage_end stage=backup status=success exit_code=0 duration_seconds=100",
            "2026-10-15T09:02:06+02:00 level=INFO event=target_update_end type=host status=success duration_seconds=121",
            host,
        ]) + "\n")
        content = content.replace(lxc + "\n", "\n".join([
            "2026-10-15T09:02:07+02:00 level=INFO event=target_update_start vmid=101 name=pihole",
            "2026-10-15T09:02:08+02:00 level=INFO event=stage_start stage=application_update command=update",
            "2026-10-15T09:02:38+02:00 level=ERROR event=stage_end stage=application_update status=failed exit_code=42 duration_seconds=30",
            "2026-10-15T09:02:39+02:00 level=INFO event=stage_start stage=recovery command=restore",
            "2026-10-15T09:02:54+02:00 level=INFO event=stage_end stage=recovery status=success exit_code=0 duration_seconds=15",
            "2026-10-15T09:03:00+02:00 level=ERROR event=target_update_end vmid=101 status=failed exit_code=42 duration_seconds=53",
            lxc,
        ]) + "\n")
        self.store(self.newer, content)
        result = self.query("status", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["duration_seconds"], 2700)
        host, lxc = data["targets"]
        self.assertEqual(host["duration_seconds"], 121)
        self.assertEqual(host["stages"], [
            {"name": "backup", "status": "success", "duration_seconds": 100},
        ])
        self.assertEqual(lxc["duration_seconds"], 53)
        self.assertEqual(lxc["stages"], [
            {"name": "application_update", "status": "failed", "duration_seconds": 30},
            {"name": "recovery", "status": "success", "duration_seconds": 15},
        ])
        human = self.query("status")
        self.assertIn("Duration: 45 m 0 s", human.stdout)
        self.assertIn("Duration: 2 m 1 s", human.stdout)
        self.assertIn("Stage backup: 1 m 40 s (success)", human.stdout)
        self.assertIn("Stage application_update: 30 s (failed)", human.stdout)
        listing = self.query("history")
        self.assertIn("duration=45 m 0 s", listing.stdout)

    def test_f146_hour_minute_second_format_preserves_json_seconds(self):
        content = self.fixture().replace(
            f"run_id={self.newer} exit_code=1\n",
            f"run_id={self.newer} exit_code=1 duration_seconds=3661\n",
        )
        self.store(self.newer, content)
        self.assertEqual(json.loads(self.query("status", "--json").stdout)
                         ["duration_seconds"], 3661)
        self.assertIn("Duration: 1 h 1 m 1 s", self.query("status").stdout)
        self.assertIn("duration=1 h 1 m 1 s", self.query("history").stdout)

    def test_f146_missing_or_incomplete_duration_is_never_inferred(self):
        self.store(self.newer, self.fixture(include_end=False))
        data = json.loads(self.query("status", "--json").stdout)
        self.assertFalse(data["complete"])
        self.assertIsNone(data["duration_seconds"])
        self.assertTrue(all(t["duration_seconds"] is None and not t["stages"]
                            for t in data["targets"]))
        self.assertIn("Duration: unknown", self.query("status").stdout)

        # Old logs without recorded timing remain backward compatible,
        # even when wall-clock timestamps are separated by 45 minutes.
        self.store(self.newer, self.fixture())
        data = json.loads(self.query("status", "--json").stdout)
        self.assertTrue(data["complete"])
        self.assertIsNone(data["duration_seconds"])

        # Malformed optional time measurements must not invent durations.
        content = self.fixture().replace("exit_code=1\n",
                                         "exit_code=1 duration_seconds=-8\n")
        self.store(self.newer, content)
        self.assertIsNone(json.loads(self.query("status", "--json").stdout)
                          ["duration_seconds"])

    def test_f146_stage_duration_requires_completed_record_and_target(self):
        content = self.fixture(include_end=False)
        host = record("HOST", type_="host", name=FQDN,
                      before="-", after="-", apt="5")
        content = content.replace(host, "\n".join([
            "2026-10-15T09:00:05+02:00 level=INFO event=target_update_start type=host",
            "2026-10-15T09:00:06+02:00 level=INFO event=stage_start stage=backup",
            # Missing stage_end and target_update_end: neither elapsed time
            # can be claimed even if another record later closes.
            host,
        ]))
        self.store(self.newer, content)
        data = json.loads(self.query("status", "--json").stdout)
        self.assertIsNone(data["duration_seconds"])
        self.assertIsNone(data["targets"][0]["duration_seconds"])
        self.assertEqual(data["targets"][0]["stages"], [])

    def test_empty_retention_and_invalid_id(self):
        self.assertIsNone(json.loads(self.query("status", "--json").stdout))
        self.assertEqual(json.loads(self.query("history", "--json").stdout), [])
        self.assertIn("No retained", self.query("status").stdout)
        self.store(self.newer, self.fixture())
        for name in ("missing", "../outside", "20261015T090000-99"):
            r = self.query("history", name)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("error", r.stderr.lower())

    def test_invalid_or_inconsistent_global_totals_fail_closed(self):
        path = self.store(self.newer, self.fixture().replace(
            "succeeded=1", "succeeded=2"))
        r = self.query("status", "--json")
        self.assertEqual(r.returncode, 2)
        self.assertIn("global result differs", r.stderr)
        path.write_text(self.fixture().replace(
            "result_global status=PARTIAL targets=2", "result_global status=SUCCESS targets=5"))
        r = self.query("history")
        self.assertEqual(r.returncode, 2)
        self.assertIn("target count differs", r.stderr)
        path.write_text(self.fixture().replace("status=PARTIAL targets=", "status=SUCCESS targets="))
        r = self.query("status")
        self.assertEqual(r.returncode, 2)
        self.assertIn("global status differs", r.stderr)

    def test_invalid_log_names_and_symlink_are_ignored(self):
        self.store(self.newer, self.fixture())
        (self.runs / "unknown.log").write_text("unused")
        (self.runs / "20261016T090000-78.log").symlink_to(self.runs / f"{self.newer}.log")
        r = self.query("history", "--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual([x["run_id"] for x in json.loads(r.stdout)], [self.newer])

    def test_public_cli_uses_configuration_without_creating_run_logs(self):
        sandbox = self.root / "sandbox"
        parts = [
            "forge", "forge.conf.default", "lib/config/get.sh",
            "lib/config/load.sh", "lib/config/validate.sh",
            "lib/runtime/require-context.sh", "lib/runtime/persistent.sh",
            "lib/runtime/persistent-worker.sh", "lib/results/history.py",
            "lib/results/table.py",
        ]
        for part in parts:
            dest = sandbox / part
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / part, dest)
        script = sandbox / "forge"
        script.write_text(script.read_text().replace(
            'LOCK_FILE="/run/lock/proxmox-forge.lock"',
            f'LOCK_FILE="{self.root / "forge.lock"}"'), encoding="utf-8")
        (sandbox / "forge.conf").write_text(f'LOG_DIR="{self.logs}"\n', encoding="utf-8")
        binaries = self.root / "bin"
        binaries.mkdir()
        host = binaries / "hostname"
        host.write_text('#!/bin/sh\nprintf "bv.deulos.com\\n"\n', encoding="utf-8")
        host.chmod(0o755)
        original = self.fixture()
        self.store(self.newer, original)
        result = subprocess.run(
            ["bash", str(script), "status", "--json"],
            capture_output=True, text=True, check=False,
            env={**os.environ, "PATH": f"{binaries}:{os.environ['PATH']}"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["run_id"], self.newer)
        self.assertEqual((self.runs / f"{self.newer}.log").read_text(), original)
        self.assertEqual(len(list(self.runs.glob("*.log"))), 1)
        self.assertEqual((self.root / "forge.lock").read_text(), "")


if __name__ == "__main__":
    unittest.main()
