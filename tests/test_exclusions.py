#!/usr/bin/env python3
"""F026: test real exact-match LXC exclusion helper without using Proxmox."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class LxcExclusionTests(unittest.TestCase):
    def check(self, vmid, hostname, exclusions):
        with tempfile.TemporaryDirectory(prefix="forge-exclude-") as tmp:
            guard = Path(tmp) / "guard.sh"
            guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
            env = {**os.environ, "FORGE_RUNTIME_GUARD": str(guard)}
            return subprocess.run(
                ["bash", "-c",
                 'source "$1/lib/lxc/exclusions.sh"; lxc_is_excluded "$2" "$3" "$4"',
                 "_", str(ROOT), vmid, hostname, exclusions],
                env=env, capture_output=True, text=True, check=False,
            )

    def test_exact_vmid(self):
        self.assertEqual(self.check("111", "share", "111").returncode, 0)

    def test_exact_hostname(self):
        self.assertEqual(self.check("111", "share", "share").returncode, 0)

    def test_mixed_entries_and_whitespace(self):
        self.assertEqual(self.check("111", "share", " 100, share , 115 ").returncode, 0)

    def test_empty_exclusions_select_everything(self):
        self.assertEqual(self.check("111", "share", "").returncode, 1)

    def test_prefix_or_substring_does_not_match(self):
        for value in ("11", "1111", "sha", "shared", "areshare"):
            with self.subTest(value=value):
                self.assertEqual(self.check("111", "share", value).returncode, 1)

    def test_case_sensitive_name(self):
        self.assertEqual(self.check("111", "share", "Share").returncode, 1)

    def test_unrelated_id_or_name_does_not_match(self):
        self.assertEqual(self.check("111", "share", "100,other,112").returncode, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
