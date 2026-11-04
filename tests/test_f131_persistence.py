#!/usr/bin/env python3
"""F131: public CLI and tmux/systemd lifecycle with isolated command fakes."""

import os
import pty
import select
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

TMUX = r"""#!/bin/bash
printf 'tmux %s\n' "$*" >> "$FORGE_TEST_CALLS"
case " $* " in
  *" has-session "*) [[ -e "$FORGE_TEST_ACTIVE" ]] ;;
  *" show-options "*) [[ -e "$FORGE_TEST_SERVER" ]] ;;
  *" new-session "*) touch "$FORGE_TEST_ACTIVE" ;;
  *" set-option "*) exit 0 ;;
  *" attach-session "*) printf 'FAKE LIVE UPDATE OUTPUT\n' ;;
  *" kill-server "*) rm -f "$FORGE_TEST_SERVER" "$FORGE_TEST_ACTIVE" ;;
  *) exit 90 ;;
esac
"""
SYSTEMD_RUN = r"""#!/bin/bash
printf 'systemd-run %s\n' "$*" >> "$FORGE_TEST_CALLS"
if [[ "${FORGE_TEST_RUN_FAIL:-false}" == true ]]; then exit 40; fi
touch "$FORGE_TEST_SERVER"
"""
SYSTEMCTL = r"""#!/bin/bash
printf 'systemctl %s\n' "$*" >> "$FORGE_TEST_CALLS"
case " $* " in
  *" show "*)
    printf 'ActiveState=active\nMainPID=1234\n'
    if [[ "${FORGE_TEST_BAD_SCOPE:-false}" == true ]]; then
      printf 'ControlGroup=/user.slice/fake.service\n'
    else
      printf 'ControlGroup=/system.slice/proxmox-forge-f131-%s.service\n' "$(id -u)"
    fi
    ;;
  *" stop "*) rm -f "$FORGE_TEST_SERVER" ;;
  *) exit 90 ;;
esac
"""


class F131Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="forge-f131-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        for name, body in (("tmux", TMUX), ("systemd-run", SYSTEMD_RUN),
                           ("systemctl", SYSTEMCTL)):
            path = bin_dir / name
            path.write_text(body, encoding="utf-8")
            path.chmod(0o755)
        self.active = self.base / "active"
        self.server = self.base / "server"
        self.calls = self.base / "calls"
        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FORGE_TEST_ACTIVE": str(self.active),
            "FORGE_TEST_SERVER": str(self.server),
            "FORGE_TEST_CALLS": str(self.calls),
            "FORGE_SELF_UPDATE_SKIP_PROMPT": "1",
        }
        self.env.pop("FORGE_PERSISTENT_INNER", None)
        self.env.pop("TMUX", None)

    def invoke(self, args):
        return subprocess.run(
            [str(ROOT / "forge"), *args], env=self.env, capture_output=True,
            text=True, check=False,
        )

    def helper(self, tail, tty=False, extra=None):
        env = {**self.env, **(extra or {})}
        src = str(ROOT / "lib/runtime/persistent.sh")
        cmd = 'PERSISTENT_SCRIPT="$1"; source "$1"; forge_persistent_init; ' + tail
        argv = ["/bin/bash", "-c", cmd, "_", src]
        if not tty:
            return subprocess.run(argv, env=env, capture_output=True,
                                  text=True, check=False)
        pid, master = pty.fork()
        if pid == 0:
            os.execve("/bin/bash", argv, env)
        output = bytearray()
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                readable, _, _ = select.select([master], [], [], 0.1)
                if readable:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output.extend(chunk)
                done, status = os.waitpid(pid, os.WNOHANG)
                if done:
                    return subprocess.CompletedProcess(argv,
                        os.waitstatus_to_exitcode(status),
                        output.decode(errors="replace"), "")
            done, status = os.waitpid(pid, os.WNOHANG)
            # PTY EOF can precede child reaping by a scheduler tick.
            for _ in range(20):
                if done:
                    break
                time.sleep(0.05)
                done, status = os.waitpid(pid, os.WNOHANG)
            if not done:
                os.kill(pid, 9)
                os.waitpid(pid, 0)
                self.fail("F131 helper hung; output=" +
                          output.decode(errors="replace") +
                          "; calls=" + self.calls_text())
            return subprocess.CompletedProcess(argv,
                os.waitstatus_to_exitcode(status),
                output.decode(errors="replace"), "")
        finally:
            os.close(master)

    def calls_text(self):
        return self.calls.read_text() if self.calls.exists() else ""

    def test_back_after_completion_reports_history_without_lock(self):
        result = self.invoke(["back"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No persistent update is running", result.stdout)
        self.assertIn("forge history", result.stdout)
        self.assertNotIn("systemd-run", self.calls_text())

    def test_active_update_gets_back_instruction_before_flock(self):
        self.active.touch()
        result = self.invoke(["host", "update"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("forge back", result.stderr)
        self.assertNotIn("systemd-run", self.calls_text())

    def test_noninteractive_enabled_preflight_fails_closed(self):
        result = self.helper("forge_persistent_prepare")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("interactive", result.stderr)
        self.assertNotIn("systemd-run", self.calls_text())

    def test_invalid_systemd_scope_rejected_before_update(self):
        result = self.helper("forge_persistent_prepare", tty=True,
                             extra={"FORGE_TEST_BAD_SCOPE": "true"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not confirmed independent", result.stdout)
        self.assertIn("systemctl --no-pager stop", self.calls_text())
        self.assertNotIn("new-session", self.calls_text())

    def test_systemd_run_failure_rejected_before_update(self):
        result = self.helper("forge_persistent_prepare", tty=True,
                             extra={"FORGE_TEST_RUN_FAIL": "true"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot start", result.stdout)
        self.assertNotIn("new-session", self.calls_text())

    def test_persistent_spawn_and_attach_keep_live_output(self):
        result = self.helper(
            'forge_persistent_prepare && '
            'forge_persistent_spawn /bin/echo host update && '
            'forge_persistent_attach', tty=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("FAKE LIVE UPDATE OUTPUT", result.stdout)
        self.assertIn("systemd-run --unit=proxmox-forge-f131-", self.calls_text())
        self.assertIn("new-session", self.calls_text())
        self.assertIn("set-option -g exit-empty on", self.calls_text())

    def test_worker_refuses_ssh_owned_scope_before_updater_mutation(self):
        output = self.base / "worker-exit"
        touched = self.base / "updated"
        updater = self.base / "update"
        updater.write_text('#!/bin/bash\ntouch "$1"\n', encoding="utf-8")
        updater.chmod(0o755)
        result = subprocess.run(
            ["bash", str(ROOT / "lib/runtime/persistent-worker.sh"),
             str(output), str(updater), str(touched)],
            env=self.env, capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertFalse(touched.exists())
        self.assertEqual(output.read_text(), "1\n")
        self.assertIn("not running in its independent systemd service", result.stderr)

    def test_running_back_attaches_without_trying_update_lock(self):
        self.active.touch()
        result = self.helper("forge_persistent_back", tty=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("FAKE LIVE UPDATE OUTPUT", result.stdout)
        self.assertNotIn("systemd-run", self.calls_text())


if __name__ == "__main__":
    unittest.main()
