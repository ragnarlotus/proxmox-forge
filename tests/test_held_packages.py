#!/usr/bin/env python3
"""F022: exercise real APT held-package detector with harmless package fakes."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

APT = r"""#!/bin/sh
[ "$#" -eq 1 ] && [ "$1" = showhold ] || exit 94
printf 'apt-mark showhold\n' >> "$FORGE_TEST_CALLS"
printf '%s' "$FORGE_TEST_HOLDS"
exit "$FORGE_TEST_APT_CODE"
"""

PCT = r"""#!/bin/sh
[ "$#" -eq 8 ] || exit 95
[ "$1" = exec ] && [ "$2" = 111 ] && [ "$3" = -- ] && \
  [ "$4" = env ] && [ "$5" = LC_ALL=C ] && \
  [ "$6" = apt-mark ] && [ "$7" = showhold ] || exit 96
printf 'pct exec 111\n' >> "$FORGE_TEST_CALLS"
[ ! -t 0 ] || exit 97
printf '%s' "$FORGE_TEST_HOLDS"
exit "$FORGE_TEST_PCT_CODE"
"""


class HeldPackagesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="forge-held-packages-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        for name, source in (("apt-mark", APT), ("pct", PCT)):
            target = bin_dir / name
            target.write_text(source, encoding="utf-8")
            target.chmod(0o755)
        guard = self.base / "guard.sh"
        guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        self.calls_path = self.base / "calls"
        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FORGE_RUNTIME_GUARD": str(guard),
            "FORGE_TEST_CALLS": str(self.calls_path),
            "FORGE_TEST_HOLDS": "",
            "FORGE_TEST_APT_CODE": "0",
            "FORGE_TEST_PCT_CODE": "0",
        }

    def invoke(self, target, **changes):
        self.calls_path.unlink(missing_ok=True)
        return subprocess.run(
            ["bash", str(ROOT / "lib/preflight/held-packages.sh"), target],
            cwd=self.base, env={**self.env, **changes},
            input="", capture_output=True, text=True, check=False,
        )

    def test_host_no_holds_reports_zero_without_notice(self):
        result = self.invoke("host")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "held_packages=0 type=host\n")
        self.assertEqual(self.calls_path.read_text(), "apt-mark showhold\n")

    def test_host_holds_report_every_name_count_and_notice(self):
        result = self.invoke(
            "host", FORGE_TEST_HOLDS="zeta\nalpha:amd64\nzeta\nlibssl3t64\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("held_package=alpha:amd64 type=host\n", result.stdout)
        self.assertIn("held_package=libssl3t64 type=host\n", result.stdout)
        self.assertIn("held_package=zeta type=host\n", result.stdout)
        self.assertIn("held_packages=3 type=host\n", result.stdout)
        self.assertLess(result.stdout.index("alpha"), result.stdout.index("zeta"))
        self.assertIn("NOTICE: Proxmox host has 3 explicitly held", result.stdout)
        self.assertEqual(self.calls_path.read_text(), "apt-mark showhold\n")

    def test_guest_checks_inside_lxc_without_update(self):
        result = self.invoke("111", FORGE_TEST_HOLDS="hold-me\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("held_package=hold-me type=lxc vmid=111\n", result.stdout)
        self.assertIn("held_packages=1 type=lxc vmid=111\n", result.stdout)
        self.assertIn("NOTICE: LXC 111 has 1 explicitly held", result.stdout)
        self.assertEqual(self.calls_path.read_text(), "pct exec 111\n")

    def test_host_failure_never_claims_zero_holds(self):
        result = self.invoke("host", FORGE_TEST_APT_CODE="42")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("could not inspect held APT packages", result.stderr)
        self.assertNotIn("held_packages=0", result.stdout)

    def test_guest_failure_never_claims_zero_holds(self):
        result = self.invoke("111", FORGE_TEST_PCT_CODE="43")
        self.assertEqual(result.returncode, 43, result.stderr)
        self.assertIn("exit code 43", result.stderr)
        self.assertNotIn("held_packages=0", result.stdout)

    def test_invalid_target_is_rejected_before_inspection(self):
        result = self.invoke("guest11;unsafe")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("numeric VMID", result.stderr)
        self.assertFalse(self.calls_path.exists())

    def test_unexpected_package_name_fails_closed(self):
        result = self.invoke("host", FORGE_TEST_HOLDS="valid\nbad package\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected package name", result.stderr)
        self.assertNotIn("held_packages=0", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
