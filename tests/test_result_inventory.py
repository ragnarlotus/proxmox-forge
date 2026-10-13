#!/usr/bin/env python3
"""F220: exercise real full-inventory policy using fake Proxmox configuration and pct."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class CompleteLxcInventoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="forge-inventory-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.config = self.base / "pve" / "lxc"
        self.config.mkdir(parents=True)

        for id, name, template in (
            (9, "old-stopped", False), (10, "new-running", False),
            (100, "wireguard", False), (111, "share", False),
            (113, "soulsync", False), (115, "trek", False),
            (120, "base-template", True),
        ):
            contents = f"hostname: {name}\n"
            if template:
                contents += "template: 1\n"
            (self.config / f"{id}.conf").write_text(contents, encoding="utf-8")

        target = self.base / "lib" / "results"
        target.mkdir(parents=True)
        source = (ROOT / "lib/results/inventory.sh").read_text(encoding="utf-8")
        locator = "configs=(/etc/pve/lxc/*.conf)"
        config_file = 'file="/etc/pve/lxc/$vmid.conf"'
        self.assertEqual(source.count(locator), 1)
        self.assertEqual(source.count(config_file), 1)
        script = source.replace(locator, f"configs=({self.config}/*.conf)")
        script = script.replace(config_file, f'file="{self.config}/$vmid.conf"')
        self.script = target / "inventory.sh"
        self.script.write_text(script, encoding="utf-8")
        lxc_dir = self.base / "lib" / "lxc"
        lxc_dir.mkdir()
        (lxc_dir / "exclusions.sh").symlink_to(ROOT / "lib/lxc/exclusions.sh")

        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        pct = bin_dir / "pct"
        pct.write_text(
            '#!/bin/bash\n'
            '[[ "$1" == status && $# -eq 2 ]] || exit 93\n'
            'case "$2" in\n'
            '  9|113) echo "status: stopped";;\n'
            '  10|100|111|115|120) echo "status: running";;\n'
            '  *) exit 94;;\n'
            'esac\n', encoding="utf-8"
        )
        pct.chmod(0o755)
        guard = self.base / "guard.sh"
        guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        self.env = {
            **os.environ,
            "FORGE_RUNTIME_GUARD": str(guard),
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
        }

    def invoke(self, enabled="true", excluded=""):
        return subprocess.run(
            ["bash", str(self.script), enabled, excluded],
            env=self.env, cwd=self.base, text=True, capture_output=True, check=False,
        )

    def records(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        items = [line.split("\t") for line in result.stdout.splitlines()]
        self.assertTrue(all(len(row) == 4 for row in items), items)
        return [(int(id), name, state, policy) for id, name, state, policy in items]

    def test_numeric_order_and_all_guests_including_stopped_and_templates(self):
        self.assertEqual(self.records(self.invoke()), [
            (9, "old-stopped", "stopped", "stopped"),
            (10, "new-running", "running", "eligible"),
            (100, "wireguard", "running", "eligible"),
            (111, "share", "running", "eligible"),
            (113, "soulsync", "stopped", "stopped"),
            (115, "trek", "running", "eligible"),
            (120, "base-template", "running", "template"),
        ])

    def test_excluded_id_and_exact_name(self):
        rows = self.records(self.invoke(excluded="100,share,113,base-template"))
        self.assertEqual({id: policy for id, _, _, policy in rows}, {
            9: "stopped", 10: "eligible", 100: "excluded", 111: "excluded",
            113: "stopped", 115: "eligible", 120: "template"
        })

    def test_disabled_running_scope_does_not_hide_stopped_or_template(self):
        rows = self.records(self.invoke(enabled="false", excluded="111"))
        self.assertEqual({id: policy for id, _, _, policy in rows}, {
            9: "stopped", 10: "running_lxc_disabled", 100: "running_lxc_disabled",
            111: "excluded", 113: "stopped", 115: "running_lxc_disabled",
            120: "template"
        })

    def test_case_sensitive_exact_exclusions(self):
        rows = self.records(self.invoke(excluded="Wireguard,1111,sh"))
        self.assertEqual(next(policy for id, _, _, policy in rows if id == 100), "eligible")

    def test_empty_inventory(self):
        for path in self.config.iterdir():
            path.unlink()
        self.assertEqual(self.records(self.invoke()), [])

    def test_invalid_hostname_fails_instead_of_recording_unsafe_name(self):
        (self.config / "100.conf").write_text("hostname: invalid name\n", encoding="utf-8")
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid hostname for LXC 100", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
