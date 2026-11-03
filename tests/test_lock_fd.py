#!/usr/bin/env python3
"""Regression: guest processes must never inherit Forge's flock descriptor."""

import fcntl
import os
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GUARD = ROOT / "lib/runtime/require-context.sh"


class GuestLockDescriptorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="forge-guest-lock-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.lock = self.root / "forge.lock"
        self.calls = self.root / "pct-calls"
        self.daemon_pid = self.root / "background-pid"
        pct = self.bin / "pct"
        pct.write_text(
            r"""#!/bin/bash
# pct mock: Forge's lock must be held by the caller, but NOT inherited here.
case "${1:-}" in exec|start|stop|shutdown) ;; *) exit 90 ;; esac
[[ ! -e /proc/$$/fd/200 ]] || {
  printf 'ERROR: guest process inherited Forge lock fd 200\n' >&2
  exit 91
}
if flock -n "$FORGE_LOCK_FILE" -c ':' >/dev/null 2>&1; then
  printf 'ERROR: Forge lock was dropped before guest execution\n' >&2
  exit 92
fi
printf '%s\n' "$*" >> "$FORGE_TEST_PCT_CALLS"
if [[ "${FORGE_TEST_SPAWN_BG:-false}" == true ]]; then
  sleep 30 </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$FORGE_TEST_DAEMON_PID"
fi
exit 0
""",
            encoding="utf-8",
        )
        pct.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "FORGE_TEST_PCT_CALLS": str(self.calls),
            "FORGE_TEST_DAEMON_PID": str(self.daemon_pid),
        }
        self.env.pop("FORGE_TEST_SPAWN_BG", None)

    def run_guarded(self, script, *args, **overrides):
        # The outer Bash owns fd 200 and the real Forge guard must accept it
        # inside the internal script before that script invokes pct.
        shell = (
            'exec 200<>"$1"; flock -n 200 || exit 98; '
            'export FORGE_CONTEXT=active FORGE_RUN_ID=lock-regression '
            'FORGE_LOCK_FILE="$1" FORGE_LOCK_FD=200 FORGE_RUNTIME_GUARD="$2"; '
            'shift 2; bash "$@"'
        )
        return subprocess.run(
            ["bash", "-c", shell, "lock-test", str(self.lock), str(GUARD),
             str(ROOT / script), *map(str, args)],
            capture_output=True, text=True, timeout=12, check=False,
            env={**self.env, **overrides},
        )

    def assert_lock_is_released(self):
        with self.lock.open("a+") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                self.fail("a process created during the run retained Forge's lock")

    def test_application_updater_background_process_cannot_retain_lock(self):
        try:
            result = self.run_guarded(
                "lib/lxc/update/application.sh", "108", "/usr/bin/update",
                FORGE_TEST_SPAWN_BG="true",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(self.daemon_pid.is_file(), result.stdout)
            self.assertEqual(len(self.calls.read_text().splitlines()), 1)
            self.assert_lock_is_released()
        finally:
            if self.daemon_pid.exists():
                pid = int(self.daemon_pid.read_text().strip())
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass

    def test_direct_pct_lifecycle_stage_does_not_pass_lock(self):
        log = self.root / "lifecycle.log"
        log.touch()
        result = self.run_guarded(
            "lib/logging/capture.sh", str(log), "lifecycle_start",
            "--", "pct", "start", "108",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("stage=start name=lifecycle_start", result.stdout)
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)
        self.assert_lock_is_released()

    def test_os_upgrade_keeps_parent_locked_but_never_passes_fd_to_pct(self):
        result = self.run_guarded("lib/lxc/update/os.sh", "108", "apt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls.read_text().splitlines()), 3)
        self.assert_lock_is_released()

    def test_custom_script_cannot_pass_lock_to_persistent_guest_process(self):
        scripts = self.root / "scripts" / "108"
        scripts.mkdir(parents=True)
        (scripts / "custom.sh").write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        result = self.run_guarded(
            "lib/lxc/update/custom-scripts.sh", "108", str(scripts.parent),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)
        self.assert_lock_is_released()

    def test_functional_health_script_never_inherits_lock(self):
        scripts = self.root / "health" / "108"
        scripts.mkdir(parents=True)
        (scripts / "check.sh").write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        result = self.run_guarded("lib/lxc/health-scripts.sh", "108",
                                  str(scripts.parent))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)
        self.assert_lock_is_released()


if __name__ == "__main__":
    unittest.main()
