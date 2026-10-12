#!/usr/bin/env python3
"""F064 regression: run the actual LXC inspection and requirements scripts.

Only external commands (pct, dpkg, ps, apt-get and df) are test doubles.
The embedded sh -c inspection payload is executed, not simulated.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TARGET = "type=lxc vmid=111 name=share state=running template=false"


class LxcInspectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="forge-inspection-")
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.lib = base / "lib"
        self.bin = base / "bin"
        self.bin.mkdir()

        paths = (
            "lxc/get-info.sh",
            "workflows/check-requirements.sh",
            "preflight/root-space.sh",
        )
        for path in paths:
            dest = self.lib / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.symlink_to(ROOT / "lib" / path)

        target = self.lib / "lxc/get-target.sh"
        target.write_text(
            '#!/bin/bash\nprintf "%s\\n" "$FORGE_TEST_TARGET_RECORD"\n',
            encoding="utf-8",
        )
        get_config = self.lib / "config/get.sh"
        get_config.parent.mkdir(parents=True, exist_ok=True)
        get_config.write_text(
            'config_get() { declare -gA CONFIG=([MIN_ROOT_FREE_MB]=1024); }\n',
            encoding="utf-8",
        )

        guard = base / "guard.sh"
        guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")

        self.make_command("pct", r"""#!/bin/bash
if [[ "$#" -ne 8 || "$1" != exec || "$2" != 111 || "$3" != -- ||
      "$4" != env || "$5" != FORGE_INFO_MODE=* || "$6" != sh || "$7" != -c ]]; then
  printf 'unexpected pct call: %s\n' "$*" >&2
  exit 90
fi
shift 3
exec "$@"
""")
        self.make_command("df", r"""#!/bin/bash
[[ "$#" -eq 2 && "$1" == -Pk && "$2" == / ]] || exit 90
printf 'df\n' >> "$FORGE_TEST_CALL_LOG"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/root 5000000 2902848 %s 59%% /\n' "$FORGE_TEST_ROOT_FREE_KB"
""")
        self.make_command("dpkg", '#!/bin/bash\n[[ "$1" == --audit ]] || exit 90\n')
        self.make_command("apt-get", "#!/bin/bash\nexit 0\n")
        self.make_command("ps", '#!/bin/bash\n[[ "$1" == -eo && "$2" == comm= ]] || exit 90\n')

        self.calls = base / "calls.log"
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ.get('PATH', '')}",
            "FORGE_RUNTIME_GUARD": str(guard),
            "FORGE_TEST_TARGET_RECORD": TARGET,
            "FORGE_TEST_ROOT_FREE_KB": "2097152",
            "FORGE_TEST_CALL_LOG": str(self.calls),
        }

    def make_command(self, name, content):
        command = self.bin / name
        command.write_text(content, encoding="utf-8")
        command.chmod(0o755)

    def invoke(self, script, *args, free_kb="2097152"):
        self.calls.unlink(missing_ok=True)
        env = {**self.env, "FORGE_TEST_ROOT_FREE_KB": free_kb}
        return subprocess.run(
            ["bash", str(self.lib / script), *args],
            env=env, capture_output=True, text=True, check=False,
        )

    def assert_one_df_call(self):
        self.assertEqual(self.calls.read_text(encoding="utf-8").splitlines(),
                         ["df"])

    def test_basic_info_reports_root_space_once(self):
        result = self.invoke("lxc/get-info.sh", "111", "", TARGET)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("root_free_kb="), 1)
        self.assertIn("root_free_kb=2097152", result.stdout)
        self.assertIn("package_manager=apt", result.stdout)
        self.assertNotIn("mem_available_kb=", result.stdout)
        self.assert_one_df_call()

    def test_full_info_reports_root_space_once(self):
        result = self.invoke("lxc/get-info.sh", "111", "all", TARGET)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("root_free_kb="), 1)
        self.assertIn("root_free_kb=2097152", result.stdout)
        self.assertIn("mem_available_kb=", result.stdout)
        self.assertIn("os_id=", result.stdout)
        self.assert_one_df_call()

    def test_target_resolution_without_existing_record(self):
        result = self.invoke("lxc/get-info.sh", "111")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("vmid=111", result.stdout)
        self.assert_one_df_call()

    def test_real_requirements_pass_using_one_measurement(self):
        result = self.invoke("workflows/check-requirements.sh", "111", TARGET)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("requirements=ok", result.stdout)
        self.assertIn("space=ok", result.stdout)
        self.assert_one_df_call()

    def test_real_requirements_reject_low_space(self):
        result = self.invoke("workflows/check-requirements.sh", "111", TARGET,
                             free_kb="1048575")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("insufficient free space", result.stderr)
        self.assertNotIn("requirements=ok", result.stdout)
        self.assert_one_df_call()

    def test_real_requirements_reject_invalid_measurement(self):
        result = self.invoke("workflows/check-requirements.sh", "111", TARGET,
                             free_kb="unknown")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid root filesystem free-space value", result.stderr)
        self.assertNotIn("requirements=ok", result.stdout)
        self.assert_one_df_call()


if __name__ == "__main__":
    unittest.main(verbosity=2)
