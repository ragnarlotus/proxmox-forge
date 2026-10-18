#!/usr/bin/env python3
"""F238: real Git repositories with isolated Forge CLI and fake SSH remote URL."""

import fcntl
import os
from pathlib import Path
import pty
import shutil
import subprocess
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
REAL_GIT = shutil.which("git")
LOCK_MARKER = 'LOCK_FILE="/run/lock/proxmox-forge.lock"'


class ForgeSelfUpdateTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="forge-self-update-")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.checkout = self.root / "forge-checkout"
        self.checkout.mkdir()
        self.remote = self.root / "remote.git"
        self.writer = self.root / "writer"

        self.git("init", "--bare", str(self.remote), cwd=self.root)
        self.git("init", "-b", "main", cwd=self.checkout)
        self.git("config", "user.email", "forge-ci@example.invalid")
        self.git("config", "user.name", "Forge CI")
        self.git("remote", "add", "origin", str(self.remote))

        forge = (ROOT / "forge").read_text()
        self.assertIn(LOCK_MARKER, forge)
        forge = forge.replace(
            LOCK_MARKER, f'LOCK_FILE="{self.root / "forge.lock"}"', 1
        )
        (self.checkout / "forge").write_text(forge)
        (self.checkout / "forge").chmod(0o755)
        (self.checkout / "forge.conf.default").write_bytes(
            (ROOT / "forge.conf.default").read_bytes()
        )
        (self.checkout / ".gitignore").write_text("forge.conf\n")
        for path in (
            "lib/self-update.sh", "lib/runtime/require-context.sh",
            "lib/config/get.sh", "lib/config/load.sh",
            "lib/config/validate.sh",
        ):
            output = self.checkout / path
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes((ROOT / path).read_bytes())
        self.git("add", ".")
        self.git("commit", "-m", "initial")
        self.git("push", "-u", "origin", "main")
        self.git("clone", str(self.remote), str(self.writer), cwd=self.root)
        self.git("config", "user.email", "forge-ci@example.invalid", cwd=self.writer)
        self.git("config", "user.name", "Forge CI", cwd=self.writer)

        # Only URL inspection is overridden: all fetch, history and worktree
        # operations use the actual git executable against a real bare remote.
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        fake_git = bin_dir / "git"
        fake_git.write_text(
            '#!/usr/bin/env python3\n'
            'import os,sys\n'
            'a=sys.argv[1:]\n'
            'if len(a)>=4 and a[-3:]==["remote","get-url","origin"]:\n'
            ' print("git@github-proxmox-forge:ragnarlotus/proxmox-forge.git")\n'
            'else:\n'
            ' os.execv(os.environ["FORGE_REAL_GIT"],'
            ' [os.environ["FORGE_REAL_GIT"],*a])\n'
        )
        fake_git.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FORGE_REAL_GIT": REAL_GIT,
        }
        guard = self.root / "stub-guard.sh"
        guard.write_text("#!/bin/bash\nexit 0\n")
        self.helper_env = {**self.env, "FORGE_RUNTIME_GUARD": str(guard)}

    def git(self, *args, cwd=None):
        return subprocess.run(
            [REAL_GIT, *args], cwd=cwd or self.checkout, check=True,
            capture_output=True, text=True,
        ).stdout.strip()

    def push_update(self, branch="main"):
        if branch != "main":
            self.git("switch", "-c", branch, cwd=self.writer)
        file = self.writer / "forge.conf.default"
        with file.open("a") as handle:
            handle.write("\n# remote update\n")
        self.git("add", "forge.conf.default", cwd=self.writer)
        self.git("commit", "-m", "remote update", cwd=self.writer)
        self.git("push", "-u", "origin", branch, cwd=self.writer)

    def run_helper(self, mode, branch="main", **env):
        return subprocess.run(
            ["bash", str(self.checkout / "lib/self-update.sh"),
             mode, str(self.checkout), branch],
            cwd=self.checkout, env={**self.helper_env, **env},
            capture_output=True, text=True,
        )

    def run_cli(self, *args, **env):
        return subprocess.run(
            [str(self.checkout / "forge"), *args], cwd=self.checkout,
            env={**self.env, **env}, capture_output=True, text=True,
        )

    def test_default_main_fast_forward_and_preserves_local_configuration(self):
        original = self.git("rev-parse", "HEAD")
        (self.checkout / "forge.conf").write_text("UPDATE_HOST=false\n")
        self.push_update()
        check = self.run_helper("check")
        self.assertEqual(check.returncode, 0, check.stderr)
        self.assertIn("self_update=available branch=main", check.stdout)
        self.assertEqual(self.git("rev-parse", "HEAD"), original)
        updated = self.run_cli("update", "self-update")
        self.assertEqual(updated.returncode, 0, updated.stderr)
        self.assertIn("self_update=success branch=main", updated.stdout)
        self.assertEqual(self.git("rev-parse", "HEAD"),
                         self.git("rev-parse", "origin/main"))
        self.assertEqual((self.checkout / "forge.conf").read_text(),
                         "UPDATE_HOST=false\n")
        again = self.run_helper("check")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("self_update=up_to_date", again.stdout)

    def test_explicit_branch_changes_only_with_ancestry(self):
        initial = self.git("rev-parse", "HEAD")
        self.push_update("experimental")
        res = self.run_cli("update", "self-update", "experimental")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.git("branch", "--show-current"), "experimental")
        self.assertEqual(self.git("rev-parse", "HEAD"),
                         self.git("rev-parse", "origin/experimental"))
        self.assertEqual(self.git("rev-parse", "main"), initial)

    def test_dirty_tracked_files_and_untracked_files_block(self):
        self.push_update()
        file = self.checkout / "forge.conf.default"
        file.write_text(file.read_text() + "\n# local edit\n")
        result = self.run_helper("update")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("local changes", result.stderr)
        self.git("checkout", "--", "forge.conf.default")
        (self.checkout / "new-unknown-file").write_text("keep me")
        result = self.run_helper("update")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("untracked files", result.stderr)

    def test_divergence_blocks_without_switching_or_rewriting(self):
        self.push_update()
        with (self.checkout / "forge.conf.default").open("a") as handle:
            handle.write("\n# local commit\n")
        self.git("add", ".")
        self.git("commit", "-m", "local ahead")
        before = self.git("rev-parse", "HEAD")
        result = self.run_helper("update")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("divergent", result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD"), before)

    def test_unknown_source_and_bad_branch_are_rejected(self):
        self.git("remote", "set-url", "origin", "https://example.net/other")
        result = self.run_helper("update")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not the approved", result.stderr)
        result = self.run_helper("update", "--bad")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid Git branch", result.stderr)

    def test_explicit_command_is_independent_of_invalid_forge_config(self):
        (self.checkout / "forge.conf").write_text("INVALID_CONFIG=yes\n")
        self.push_update()
        result = self.run_cli("update", "self-update")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("self_update=success", result.stdout)

    def test_no_version_check_when_flag_disabled(self):
        result = self.run_cli("help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("update self-update [BRANCH]", result.stdout)

    def test_prompt_can_cancel_system_update_before_any_mutation(self):
        self.push_update()
        (self.checkout / "forge.conf").write_text(
            "CHECK_FORGE_UPDATES_BEFORE_UPDATE=true\n"
        )
        master, slave = pty.openpty()

        def controlling_tty():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

        proc = subprocess.Popen(
            [str(self.checkout / "forge"), "host", "update"],
            cwd=self.checkout, env=self.env, stdin=slave,
            stdout=slave, stderr=slave, preexec_fn=controlling_tty,
        )
        os.close(slave)
        output = b""
        try:
            # Send cancellation only once prompt appears.
            for _ in range(100):
                try:
                    import select
                    ready, _, _ = select.select([master], [], [], 0.1)
                    if ready:
                        data = os.read(master, 32768)
                        output += data
                        if b"Update Forge first?" in output:
                            os.write(master, b"c\n")
                            break
                except OSError:
                    break
            proc.wait(timeout=15)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn(b"System update cancelled", output +
                          self.read_remaining(master))
            self.assertEqual(self.git("rev-parse", "HEAD"),
                             self.git("rev-parse", "main"))
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            os.close(master)

    @staticmethod
    def read_remaining(master):
        import select
        chunks = []
        while select.select([master], [], [], 0)[0]:
            try:
                chunks.append(os.read(master, 8192))
            except OSError:
                break
        return b"".join(chunks)


if __name__ == "__main__":
    unittest.main()
