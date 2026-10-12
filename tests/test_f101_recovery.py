#!/usr/bin/env python3
"""F101: verify actual rollback workflow reruns real functional checks."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PCT = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys

args = sys.argv[1:]
with Path(os.environ["FORGE_TEST_CALLS"]).open("a") as stream:
    stream.write(json.dumps(["pct", *args[:4]]) + "\n")

if args in (["stop", "111"], ["rollback", "111", "Update_test"],
            ["start", "111"]):
    sys.exit(0)
if args[:3] != ["exec", "111", "--"]:
    sys.exit(f"unexpected pct: {args}")
if args[3:] == ["true"]:
    sys.exit(0)
if args[3:5] == ["sh", "-c"]:
    print("other")
    sys.exit(0)
if args[3:] == ["bash", "-s", "--"]:
    sys.exit(subprocess.run(
        ["bash", "-s", "--"], input=sys.stdin.read(), text=True, check=False,
    ).returncode)
sys.exit(f"unexpected pct: {args}")
"""

CAPTURE = r"""#!/bin/bash
[[ $# -ge 5 && "$3" == -- ]] || exit 98
shift 3
"$@"
"""

WRITE = r"""#!/bin/bash
printf '%s\n' "$*" >> "$FORGE_TEST_EVENTS"
"""


class FunctionalRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="forge-health-recovery-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        lxc = self.base / "lib" / "lxc"
        lxc.mkdir(parents=True)
        for name in ("recover.sh", "health.sh", "health-scripts.sh"):
            (lxc / name).symlink_to(ROOT / "lib/lxc" / name)
        (lxc / "get-state.sh").write_text(
            "#!/bin/bash\nprintf 'running\\n'\n", encoding="utf-8",
        )
        config = self.base / "lib" / "config"
        config.mkdir()
        (config / "get.sh").write_text(
            'config_get() { declare -gA CONFIG=(\n'
            '  [HEALTH_SCRIPTS_DIR]="$FORGE_TEST_HEALTH_DIR"\n'
            '); }\n', encoding="utf-8",
        )
        backup = self.base / "lib" / "backup" / "lxc"
        backup.mkdir(parents=True)
        (backup / "restore.sh").write_text("#!/bin/bash\nexit 97\n", encoding="utf-8")
        logs = self.base / "lib" / "logging"
        logs.mkdir(parents=True)
        (logs / "capture.sh").write_text(CAPTURE, encoding="utf-8")
        (logs / "write.sh").write_text(WRITE, encoding="utf-8")
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        pct = bin_dir / "pct"
        pct.write_text(PCT, encoding="utf-8")
        pct.chmod(0o755)
        guard = self.base / "guard.sh"
        guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        self.calls = self.base / "calls.jsonl"
        self.events = self.base / "events.log"
        self.log = self.base / "update.log"
        self.log.touch()
        self.health_dir = self.base / "health.d" / "111"
        self.health_dir.mkdir(parents=True)
        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FORGE_RUNTIME_GUARD": str(guard),
            "FORGE_TEST_CALLS": str(self.calls),
            "FORGE_TEST_EVENTS": str(self.events),
            "FORGE_TEST_HEALTH_DIR": str(self.health_dir.parent),
        }

    def recover(self):
        return subprocess.run(
            ["bash", str(self.base / "lib/lxc/recover.sh"),
             "111", "backups:backup/test.tar.zst", "Update_test",
             str(self.log), "true", "snapshot", "health", "42"],
            cwd=self.base, env=self.env,
            capture_output=True, text=True, check=False,
        )

    def pct_calls(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_recovery_rechecks_functional_health(self):
        (self.health_dir / "01-service.sh").write_text(
            "printf 'functional-restored\\n'\n", encoding="utf-8",
        )
        result = self.recover()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("functional-restored", result.stdout)
        self.assertIn("functional_health=ok vmid=111 count=1", result.stdout)
        calls = self.pct_calls()
        self.assertEqual(sum(c[:2] == ["pct", "rollback"] for c in calls), 1)
        self.assertEqual(sum(c[:2] == ["pct", "start"] for c in calls), 1)
        self.assertEqual(sum(c[4:] == ["bash"] for c in calls), 1)
        self.assertIn("recovery_end vmid=111 status=success", self.events.read_text())

    def test_failed_functional_recheck_marks_recovery_failed(self):
        (self.health_dir / "01-service.sh").write_text(
            "printf 'still-broken\\n'\nexit 23\n", encoding="utf-8",
        )
        result = self.recover()
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertIn("still-broken", result.stdout)
        self.assertIn("recovery_end vmid=111 status=failed step=health exit_code=23",
                      self.events.read_text())
        calls = self.pct_calls()
        self.assertEqual(sum(c[:2] == ["pct", "rollback"] for c in calls), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
