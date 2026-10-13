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
