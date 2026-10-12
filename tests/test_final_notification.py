#!/usr/bin/env python3
"""F157: validate the reusable final plain-text notification renderer."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class FinalNotificationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="forge-notify-")
        self.addCleanup(self.tmp.cleanup)
        guard = Path(self.tmp.name) / "guard.sh"
        guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        self.env = {**os.environ, "FORGE_RUNTIME_GUARD": str(guard)}

    def render(self, *args):
        return subprocess.run(
            ["bash", str(ROOT / "lib/notifications/final.sh"), *args],
            env=self.env, cwd=ROOT, text=True, capture_output=True, check=False,
        )

    def test_host_success(self):
        result = self.render("host", "success", "bv.deulo.com", "none", "0", "yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Subject: [Proxmox Forge] SUCCESS - Host bv.deulo.com", result.stdout)
        self.assertIn("Restart required: yes", result.stdout)

    def test_host_failure_preserves_stage(self):
        result = self.render("host", "failed", "bv.deulo.com", "os_update", "42", "unknown")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Status: FAILED", result.stdout)
        self.assertIn("Failed stage: os_update\nExit code: 42", result.stdout)
        self.assertNotIn("Host update: completed", result.stdout)

    def test_lxc_success(self):
        result = self.render("lxc", "success", "111", "none", "0", "no")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Subject: [Proxmox Forge] SUCCESS - LXC 111", result.stdout)

    def test_lxc_failure(self):
        result = self.render("lxc", "failed", "111", "health", "23", "unknown")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Target: LXC 111", result.stdout)
        self.assertIn("Failed stage: health", result.stdout)
        self.assertIn("Exit code: 23", result.stdout)

    def test_bulk_partial(self):
        result = self.render("bulk", "partial", "all", "success", "3", "2", "1", "111:42")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Status: PARTIAL", result.stdout)
        self.assertIn("Host: SUCCESS", result.stdout)
        self.assertIn("LXCs selected: 3", result.stdout)
        self.assertIn("LXCs succeeded: 2", result.stdout)
        self.assertIn("LXCs failed: 1", result.stdout)
        self.assertIn("Failed LXC: 111 (exit code 42)", result.stdout)

    def test_bulk_all_failed(self):
        result = self.render("bulk", "failed", "lxc", "skipped", "2", "0", "2",
                             "111:2", "115:42")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Status: FAILED", result.stdout)
        self.assertNotIn("Host:", result.stdout)
        self.assertIn("Failed LXC: 115 (exit code 42)", result.stdout)

    def test_preflight_failure(self):
        result = self.render("preflight", "failed", "all", "LXC protection conflicts")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Phase: preflight", result.stdout)
        self.assertIn("Reason: LXC protection conflicts", result.stdout)
        self.assertIn("No updates started.", result.stdout)

    def test_stage_specific_error_message_and_exact_log(self):
        log = Path(self.tmp.name) / "run.log"
        log.write_text(
            "2026-10-12 level=INFO event=stage_start stage=os_update\n"
            "ERROR: old unrelated package failure\n"
            "2026-10-12 level=ERROR event=stage_end stage=os_update status=failed\n"
            "2026-10-12 level=INFO event=stage_start stage=application_update\n"
            "ERROR: actual application failure\n"
            "2026-10-12 level=ERROR event=stage_end stage=application_update status=failed\n"
            "ERROR: later cleanup problem\n",
            encoding="utf-8",
        )
        result = self.render(
            "lxc", "failed", "111", "application_update", "42", "unknown", str(log)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"Log: {log}", result.stdout)
        self.assertIn("Last error message: ERROR: actual application failure", result.stdout)
        self.assertNotIn("old unrelated", result.stdout)
        self.assertNotIn("later cleanup problem", result.stdout)

    def test_no_diagnostic_does_not_invent_cause(self):
        log = Path(self.tmp.name) / "run.log"
        log.write_text(
            "2026-10-12 level=INFO event=stage_start stage=health\n"
            "health=failed\n"
            "2026-10-12 level=ERROR event=stage_end stage=health status=failed\n",
            encoding="utf-8",
        )
        result = self.render(
            "lxc", "failed", "111", "health", "23", "unknown", str(log)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"Log: {log}", result.stdout)
        self.assertNotIn("Last error message:", result.stdout)

    def test_sensitive_error_diagnostic_is_redacted(self):
        log = Path(self.tmp.name) / "run.log"
        log.write_text(
            "level=INFO event=stage_start stage=application_update\n"
            "ERROR: token=very-sensitive-value\n"
            "level=ERROR event=stage_end stage=application_update status=failed\n",
            encoding="utf-8",
        )
        result = self.render(
            "lxc", "failed", "111", "application_update", "17", "unknown", str(log)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("diagnostic redacted", result.stdout)
        self.assertNotIn("very-sensitive-value", result.stdout)

    def test_bulk_reads_failure_metadata_when_available(self):
        detail_dir = Path(self.tmp.name) / "details"
        detail_dir.mkdir()
        log = Path(self.tmp.name) / "failed.log"
        log.write_text(
            "level=INFO event=stage_start stage=os_update\n"
            "ERROR: blocked upgrade transaction\n"
            "level=ERROR event=stage_end stage=os_update status=failed\n",
            encoding="utf-8",
        )
        (detail_dir / "lxc-111").write_text(
            f"stage=os_update\nlog={log}\n", encoding="utf-8"
        )
        old_env = self.env
        self.env = {**old_env, "FORGE_NOTIFICATION_DETAIL_DIR": str(detail_dir)}
        try:
            result = self.render("bulk", "partial", "all", "success", "3", "2", "1", "111:42")
        finally:
            self.env = old_env
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Failed stage: os_update", result.stdout)
        self.assertIn(f"Log: {log}", result.stdout)
        self.assertIn("Last error message: ERROR: blocked upgrade transaction", result.stdout)

    def test_bad_counts_rejected(self):
        result = self.render("bulk", "partial", "lxc", "skipped", "2", "2", "1", "111:42")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid target counts", result.stderr)

    def test_single_target_rejects_partial(self):
        result = self.render("lxc", "partial", "111", "none", "0", "no")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("partial is not valid", result.stderr)

    def test_rejects_line_break_in_preflight_reason(self):
        result = self.render("preflight", "failed", "all", "first\nSubject: forged")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid failure reason", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
