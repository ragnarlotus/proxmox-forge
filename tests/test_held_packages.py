#!/usr/bin/env python3
"""F022: verify only held APT packages with available upgrades are reported."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

APT = r"""#!/bin/sh
[ "$#" -eq 1 ] && [ "$1" = showhold ] || exit 94
printf 'apt-mark\n' >> "$FORGE_TEST_CALLS"
printf '%s' "$FORGE_TEST_HOLDS"
exit "$FORGE_TEST_APT_CODE"
"""

CACHE = r"""#!/bin/sh
[ "$#" -eq 2 ] && [ "$1" = policy ] || exit 95
printf 'apt-cache %s\n' "$2" >> "$FORGE_TEST_CALLS"
[ "$FORGE_TEST_CACHE_CODE" = 0 ] || exit "$FORGE_TEST_CACHE_CODE"
candidate=1.0
case ",$FORGE_TEST_OUTDATED," in
  *,"$2",*) candidate=2.0 ;;
esac
printf '%s\n' "$2:"
printf '  Installed: 1.0\n'
printf '  Candidate: %s\n' "$candidate"
"""

DPKG = r"""#!/bin/sh
[ "$#" -eq 4 ] && [ "$1" = --compare-versions ] || exit 96
printf 'dpkg %s\n' "$2" >> "$FORGE_TEST_CALLS"
exec /usr/bin/dpkg "$@"
"""

PCT = r"""#!/bin/bash
[[ $# -eq 8 && "$1" == exec && "$2" == 111 && "$3" == -- &&
   "$4" == bash && "$5" == -c && "$7" == _ && "$8" == 111 ]] || exit 97
printf 'pct exec 111\n' >> "$FORGE_TEST_CALLS"
[[ ! -t 0 ]] || exit 98
shift 3
[[ "$FORGE_TEST_PCT_CODE" == 0 ]] || exit "$FORGE_TEST_PCT_CODE"
exec "$@"
"""


class HeldPackagesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="forge-held-packages-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        for name, content in (
            ("apt-mark", APT),
            ("apt-cache", CACHE),
            ("dpkg", DPKG),
            ("pct", PCT),
        ):
            target = bin_dir / name
            target.write_text(content, encoding="utf-8")
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
            "FORGE_TEST_OUTDATED": "",
            "FORGE_TEST_APT_CODE": "0",
            "FORGE_TEST_CACHE_CODE": "0",
            "FORGE_TEST_PCT_CODE": "0",
        }

    def invoke(self, target, **changes):
        self.calls_path.unlink(missing_ok=True)
        return subprocess.run(
            ["bash", str(ROOT / "lib/preflight/held-packages.sh"), target],
            cwd=self.base, env={**self.env, **changes},
            input="", capture_output=True, text=True, check=False,
        )

    def calls(self):
        return self.calls_path.read_text(encoding="utf-8").splitlines()

    def test_no_holds_is_silent(self):
        result = self.invoke("host")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.calls(), ["apt-mark"])

    def test_held_package_with_no_upgrade_is_silent(self):
        result = self.invoke("host", FORGE_TEST_HOLDS="alpha\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.calls(), ["apt-mark", "apt-cache alpha", "dpkg 1.0"])

    def test_host_warns_only_for_outdated_holds(self):
        result = self.invoke(
            "host", FORGE_TEST_HOLDS="zeta\nalpha:amd64\nzeta\nstable\n",
            FORGE_TEST_OUTDATED="zeta,alpha:amd64",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("held_upgrade_pending=alpha:amd64 installed=1.0 candidate=2.0 type=host\n",
                      result.stdout)
        self.assertIn("held_upgrade_pending=zeta installed=1.0 candidate=2.0 type=host\n",
                      result.stdout)
        self.assertNotIn("held_upgrade_pending=stable", result.stdout)
        self.assertIn("held_upgrades_pending=2 type=host", result.stdout)
        self.assertIn("WARNING: 2 explicitly held", result.stdout)
        self.assertEqual(self.calls().count("apt-cache zeta"), 1)

    def test_guest_runs_inside_lxc_once(self):
        result = self.invoke(
            "111", FORGE_TEST_HOLDS="bar\n", FORGE_TEST_OUTDATED="bar",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("held_upgrade_pending=bar installed=1.0 candidate=2.0 type=lxc vmid=111",
                      result.stdout)
        self.assertIn("held_upgrades_pending=1 type=lxc vmid=111", result.stdout)
        self.assertEqual(self.calls().count("pct exec 111"), 1)

    def test_hold_read_failure_is_error_not_clean(self):
        result = self.invoke("host", FORGE_TEST_APT_CODE="42")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not inspect pending held APT upgrades", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_policy_failure_is_error(self):
        result = self.invoke("host", FORGE_TEST_HOLDS="foo\n",
                             FORGE_TEST_CACHE_CODE="42")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not inspect pending held APT upgrades", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_guest_failure_never_reports_clean(self):
        result = self.invoke("111", FORGE_TEST_PCT_CODE="43")
        self.assertEqual(result.returncode, 43, result.stderr)
        self.assertIn("exit code 43", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_invalid_target_is_rejected_before_inspection(self):
        result = self.invoke("guest11;unsafe")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("numeric VMID", result.stderr)
        self.assertFalse(self.calls_path.exists())

    def test_invalid_held_package_fails_closed(self):
        result = self.invoke("host", FORGE_TEST_HOLDS="bad package\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid held APT package name", result.stderr)
        self.assertNotIn("held_upgrades_pending", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
