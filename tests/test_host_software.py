#!/usr/bin/env python3
"""Read-only host platform version facts, including pending kernel difference."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "lib/results/host-software.sh"


class HostSoftwareTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="forge-host-versions-")
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        (self.bin / "pveversion").write_text(
            '#!/bin/sh\nprintf "%s\\n" "$TEST_PVE_VERSION"\n'
        )
        (self.bin / "uname").write_text(
            '#!/bin/sh\n[ "$1" = -r ] || exit 9\nprintf "%s\\n" "$TEST_KERNEL"\n'
        )
        for path in self.bin.iterdir():
            path.chmod(0o755)
        self.reboot = self.dir / "reboot.sh"
        self.reboot.write_text(
            '#!/bin/sh\n[ "$1" = host ] || exit 9\n'
            'printf "reboot_required=yes type=host marker=no '
            'kernel_update=yes running_kernel=%s '
            'latest_installed_kernel=%s\\n" "$TEST_KERNEL" "$TEST_INSTALLED_KERNEL"\n'
        )
        self.os_file = self.dir / "os-release"
        source = HELPER.read_text(encoding="utf-8")
        self.assertIn("/etc/os-release", source)
        source = source.replace("/etc/os-release", str(self.os_file))
        self.helper = self.dir / "host-software.sh"
        self.helper.write_text(source, encoding="utf-8")
        self.env = {
            **os.environ,
            "PATH": str(self.bin) + ":" + os.environ["PATH"],
            "TEST_PVE_VERSION": "pve-manager/9.0.11/abcdef",
            "TEST_KERNEL": "7.0.14-25-pve",
            "TEST_INSTALLED_KERNEL": "7.0.14-26-pve",
        }
        self.os_file.write_text(
            'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"\n'
            'ID=debian\nVERSION_ID="13"\n',
            encoding="utf-8",
        )

    def run_probe(self, **overrides):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; forge_host_software "$2"',
             "_", str(self.helper), str(self.reboot)],
            capture_output=True, text=True, check=False,
            env={**self.env, **overrides},
        )

    def test_pve_debian_running_and_installed_kernel(self):
        r = self.run_probe()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(
            r.stdout.strip(),
            "Proxmox VE 9.0.11; Debian 13; Kernel running 7.0.14-25-pve; "
            "Latest installed kernel 7.0.14-26-pve",
        )

    def test_same_kernel_only_reported_once(self):
        r = self.run_probe(TEST_INSTALLED_KERNEL="7.0.14-25-pve")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("Latest installed kernel", r.stdout)
        self.assertIn("Kernel running 7.0.14-25-pve", r.stdout)

    def test_missing_or_unparseable_facts_are_not_guessed(self):
        self.os_file.write_text('ID=ubuntu\nVERSION_ID="24.04"\n')
        r = self.run_probe(TEST_PVE_VERSION="unrecognized",
                           TEST_KERNEL="unknown",
                           TEST_INSTALLED_KERNEL="invalid")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "")

    def test_reboot_helper_failure_keeps_other_verified_facts(self):
        self.reboot.write_text('#!/bin/sh\nexit 8\n')
        r = self.run_probe()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Proxmox VE 9.0.11", r.stdout)
        self.assertIn("Kernel running 7.0.14-25-pve", r.stdout)
        self.assertNotIn("Latest installed kernel", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
