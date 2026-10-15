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
            "lib/runtime/require-context.sh", "lib/results/history.py",
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
