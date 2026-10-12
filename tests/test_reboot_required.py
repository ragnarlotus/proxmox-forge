#!/usr/bin/env python3
"""F094: execute the real reboot indicator helper without touching Proxmox."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "lib/postflight/reboot-required.sh"


class RebootRequiredTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="forge-reboot-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.boot = self.base / "boot"
        self.boot.mkdir()
        self.marker = self.base / "reboot-required"
        self.guard = self.base / "guard.sh"
        self.guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        self.bin = self.base / "bin"
        self.bin.mkdir()
        (self.bin / "uname").write_text(
            '#!/bin/bash\n[[ "$1" == -r ]] || exit 90\n'
            'printf "%s\\n" "$FORGE_TEST_RUNNING_KERNEL"\n', encoding="utf-8",
        )
        (self.bin / "pct").write_text(
            '#!/bin/bash\n'
            '[[ $# -eq 6 && "$1" == exec && "$2" == 111 && "$3" == -- '
            '&& "$4" == sh && "$5" == -c && "$6" == *reboot-required* ]] || exit 90\n'
            '[[ "$FORGE_TEST_PCT_FAILURE" == no ]] || exit 78\n'
            'printf "%s" "$FORGE_TEST_LXC_MARKER"\n',
            encoding="utf-8",
        )
        for name in ("uname", "pct"):
            (self.bin / name).chmod(0o755)

        original = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(original.count("kernel_files=(/boot/vmlinuz-*-pve)"), 1)
        self.assertEqual(original.count("/run/reboot-required"), 2)
        original = original.replace(
            "kernel_files=(/boot/vmlinuz-*-pve)",
            f"kernel_files=({self.boot}/vmlinuz-*-pve)",
        ).replace("/run/reboot-required", str(self.marker))
        self.script = self.base / "reboot-required.sh"
        self.script.write_text(original, encoding="utf-8")

        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "FORGE_RUNTIME_GUARD": str(self.guard),
            "FORGE_TEST_RUNNING_KERNEL": "7.0.14-14-pve",
            "FORGE_TEST_PCT_FAILURE": "no",
            "FORGE_TEST_LXC_MARKER": "no",
        }

    def installed_kernel(self, version):
        (self.boot / f"vmlinuz-{version}").touch()

    def run_check(self, target="host", **overrides):
        return subprocess.run(
            ["bash", str(self.script), target],
            env={**self.env, **overrides},
            capture_output=True, text=True, check=False,
        )

    def test_running_current_kernel_without_marker(self):
        self.installed_kernel("7.0.14-14-pve")
        self.installed_kernel("7.0.14-12-pve")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reboot_required=no type=host marker=no kernel_update=no", result.stdout)

    def test_newer_installed_proxmox_kernel_indicates_reboot(self):
        self.installed_kernel("7.0.14-14-pve")
        self.installed_kernel("7.0.14-16-pve")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reboot_required=yes type=host marker=no kernel_update=yes", result.stdout)
        self.assertIn("latest_installed_kernel=7.0.14-16-pve", result.stdout)

    def test_marker_indicates_reboot_without_newer_kernel(self):
        self.installed_kernel("7.0.14-14-pve")
        self.marker.touch()
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reboot_required=yes type=host marker=yes kernel_update=no", result.stdout)

    def test_missing_kernel_inventory_is_unknown(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reboot_required=unknown type=host marker=no kernel_update=unknown", result.stdout)

    def test_marker_with_missing_kernel_inventory_is_still_yes(self):
        self.marker.touch()
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reboot_required=yes type=host marker=yes kernel_update=unknown", result.stdout)

    def test_guest_marker_on(self):
        result = self.run_check("111", FORGE_TEST_LXC_MARKER="yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "reboot_required=yes type=lxc vmid=111 marker=yes")

    def test_guest_marker_off(self):
        result = self.run_check("111")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "reboot_required=no type=lxc vmid=111 marker=no")

    def test_guest_pct_failure_is_authoritative(self):
        result = self.run_check("111", FORGE_TEST_PCT_FAILURE="yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not check reboot indicator", result.stderr)
        self.assertNotIn("reboot_required=", result.stdout)

    def test_guest_invalid_response_fails_closed(self):
        result = self.run_check("111", FORGE_TEST_LXC_MARKER="garbage")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid reboot indicator response", result.stderr)

    def test_invalid_target_rejected(self):
        result = self.run_check("share")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("numeric LXC VMID", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
