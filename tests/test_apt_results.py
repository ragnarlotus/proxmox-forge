#!/usr/bin/env python3
"""F221: real dpkg snapshot comparison, independent of APT logs and simulations."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "lib/results/apt.sh"


class AptUpgradeFactsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="forge-apt-count-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.before = self.path / "before"
        self.after = self.path / "after"
        self.changed = self.path / "changed"

    def delta(self, before, after):
        self.before.write_text(before, encoding="utf-8")
        self.after.write_text(after, encoding="utf-8")
        return subprocess.run(
            ["bash", "-c",
             'source "$1"; forge_apt_delta "$2" "$3" "$4"',
             "_", str(HELPER), str(self.before), str(self.after),
             str(self.changed)],
            capture_output=True, text=True, check=False,
        )

    def test_upgraded_only_not_new_removed_autoremoved_or_downgraded(self):
        result = self.delta(
            "up\t1.0\nstable\t3.0\ndown\t9.0\nremoved\t1.0\nheld\t5.0\n",
            "up\t1.2\nstable\t3.0\ndown\t8.0\nnew\t1.0\nheld\t5.0\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "1")

    def test_zero_if_no_versions_actually_changed(self):
        self.assertEqual(self.delta("held\t2.0\n", "held\t2.0\n").stdout.strip(), "0")

    def test_epoch_and_debian_revision_comparison(self):
        result = self.delta(
            "pkg:amd64\t1:2.0-1\np2\t3.0-1\n",
            "pkg:amd64\t2:1.0-1\np2\t3.0-2\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "2")

    def test_reverted_packages_do_not_count(self):
        result = self.delta("changed\t1.0\n", "changed\t1.0\n")
        self.assertEqual(result.stdout.strip(), "0")

    def test_empty_or_invalid_measurement_is_not_zero(self):
        self.assertNotEqual(self.delta("", "pkg\t1\n").returncode, 0)
        self.assertNotEqual(self.delta("pkg\t1\n", "").returncode, 0)
        self.assertNotEqual(self.delta("pkg\tbad version\n", "pkg\t2\n").returncode, 0)

    def test_real_host_snapshot_filters_only_fully_installed_packages(self):
        bin_dir = self.path / "bin"
        bin_dir.mkdir()
        fake = bin_dir / "dpkg-query"
        fake.write_text(
            '#!/bin/bash\n'
            '[[ "$1" == -W && "$2" == -f=* ]] || exit 81\n'
            'printf "pkg:amd64\\t1.0\\tii \\n"\n'
            'printf "unpacked\\t2.0\\tiU \\n"\n'
            'printf "removed\\t3.0\\trc \\n"\n',
            encoding="utf-8",
        )
        fake.chmod(0o755)
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; forge_apt_snapshot host',
             "_", str(HELPER)],
            env={**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}"},
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "pkg:amd64\t1.0\n")

    def test_lifecycle_count_after_simulated_rollback(self):
        bin_dir = self.path / "bin"
        bin_dir.mkdir()
        current = self.path / "installed"
        current.write_text("pkg\t1.0\tii \n", encoding="utf-8")
        fake = bin_dir / "dpkg-query"
        fake.write_text('#!/bin/bash\ncat "$APT_TEST_STATE"\n', encoding="utf-8")
        fake.chmod(0o755)
        result = subprocess.run(
            ["bash", "-c",
             'source "$1"; forge_apt_begin host || exit 91; '
             'FORGE_APT_ACTIVE=true; '
             'printf "pkg\\t2.0\\tii \\n" > "$2"; '
             'printf "pkg\\t1.0\\tii \\n" > "$2"; '
             'forge_apt_finalize host; printf "%s\\n" "$FORGE_APT_COUNT"',
             "_", str(HELPER), str(current)],
            env={**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}",
                 "APT_TEST_STATE": str(current)},
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "0")

    def test_snapshot_failure_propagates_not_silent_zero(self):
        bin_dir = self.path / "bin"
        bin_dir.mkdir()
        fake = bin_dir / "dpkg-query"
        fake.write_text("#!/bin/sh\nexit 42\n", encoding="utf-8")
        fake.chmod(0o755)
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; forge_apt_snapshot host',
             "_", str(HELPER)],
            env={**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}"},
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 42)
        self.assertEqual(result.stdout, "")

    def test_lxc_snapshot_executes_read_only_dpkg_query(self):
        bin_dir = self.path / "bin"
        bin_dir.mkdir()
        fake = bin_dir / "pct"
        fake.write_text(
            '#!/bin/bash\n'
            '[[ "$1" == exec && "$2" == 111 && "$3" == -- && "$4" == dpkg-query ]] || exit 90\n'
            'printf "inside\\t4.5\\tii \\n"\n',
            encoding="utf-8",
        )
        fake.chmod(0o755)
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; forge_apt_snapshot 111',
             "_", str(HELPER)],
            env={**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}"},
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "inside\t4.5\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
