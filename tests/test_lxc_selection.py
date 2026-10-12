#!/usr/bin/env python3
"""F026: run the real LXC listing logic with isolated Proxmox config fixtures.

Only its /etc/pve/lxc glob is redirected into the temporary test directory.
The real exclusions helper is sourced and fake pct reports guest states.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class SelectedLxcScopeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="forge-lxc-scope-")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        scripts = root / "lib" / "lxc"
        scripts.mkdir(parents=True)
        self.config_dir = root / "pve" / "lxc"
        self.config_dir.mkdir(parents=True)
        for vmid, name, is_template in (
            ("100", "wireguard", False),
            ("111", "share", False),
            ("115", "trek", False),
            ("113", "soulsync", False),
            ("120", "base-template", True),
        ):
            value = f"hostname: {name}\n"
            if is_template:
                value += "template: 1\n"
            (self.config_dir / f"{vmid}.conf").write_text(value, encoding="utf-8")

        # Exercise the actual production listing implementation, changing
        # only its filesystem fixture locator to avoid touching /etc/pve.
        original = (ROOT / "lib/lxc/list-targets.sh").read_text(encoding="utf-8")
        locator = "config_files=(/etc/pve/lxc/*.conf)"
        self.assertEqual(original.count(locator), 1)
        self.script = scripts / "list-targets.sh"
        self.script.write_text(
            original.replace(locator, f"config_files=({self.config_dir}/*.conf)"),
            encoding="utf-8",
        )
        (scripts / "exclusions.sh").symlink_to(ROOT / "lib/lxc/exclusions.sh")

        tools = root / "bin"
        tools.mkdir()
        pct = tools / "pct"
        pct.write_text(
            '#!/bin/bash\n'
            '[[ "$1" == status && $# == 2 ]] || exit 98\n'
            'case "$2" in\n'
            '  113) echo "status: stopped" ;;\n'
            '  100|111|115|120) echo "status: running" ;;\n'
            '  *) exit 99 ;;\n'
            'esac\n',
            encoding="utf-8",
        )
        pct.chmod(0o755)
        guard = root / "guard.sh"
        guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        self.env = {
            **os.environ,
            "FORGE_RUNTIME_GUARD": str(guard),
            "FORGE_RUN_ID": "test-run",
            "FORGE_LXC_ENVIRONMENT_READY": "test-run",
            "PATH": f"{tools}:{os.environ.get('PATH', '')}",
        }

    def list(self, enabled="true", exclude=""):
        return subprocess.run(
            ["bash", str(self.script), enabled, exclude],
            env=self.env, capture_output=True, text=True, check=False,
        )

    def assert_vmids(self, result, expected):
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = [field.split("=", 1)[1]
                  for line in result.stdout.splitlines()
                  for field in line.split() if field.startswith("vmid=")]
        self.assertEqual(actual, expected)

    def test_default_lists_all_running_non_templates(self):
        self.assert_vmids(self.list(), ["100", "111", "115"])

    def test_exact_id_filters_running_guest(self):
        self.assert_vmids(self.list(exclude="111"), ["100", "115"])

    def test_exact_hostname_filters_running_guest(self):
        self.assert_vmids(self.list(exclude="share"), ["100", "115"])

    def test_multiple_exclusions_and_whitespace(self):
        self.assert_vmids(self.list(exclude=" 100, share "), ["115"])

    def test_prefix_and_case_do_not_filter(self):
        self.assert_vmids(self.list(exclude="sh,Share,11"), ["100", "111", "115"])

    def test_all_excluded_is_empty_success(self):
        self.assert_vmids(self.list(exclude="100,share,115"), [])

    def test_stopped_guest_and_template_never_selected(self):
        self.assert_vmids(self.list(exclude="113,base-template"), ["100", "111", "115"])

    def test_disabled_selection_is_empty_even_with_exclusions(self):
        self.assert_vmids(self.list(enabled="false", exclude="111"), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
