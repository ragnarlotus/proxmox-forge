#!/usr/bin/env python3
"""F141: one retained execution log without altering target logs or exit codes."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INIT = ROOT / "lib/logging/init.sh"
WRITE = ROOT / "lib/logging/write.sh"
CAPTURE = ROOT / "lib/logging/capture.sh"
TABLE = ROOT / "lib/results/table.py"


class RunLoggingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="forge-f141-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        host = self.bin / "hostname"
        host.write_text('#!/bin/sh\nprintf "bv.deulos.com\\n"\n', encoding="utf-8")
        host.chmod(0o755)
        self.guard = self.root / "guard.sh"
        self.guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:" + os.environ["PATH"],
            "FORGE_RUNTIME_GUARD": str(self.guard),
            "FORGE_RUN_ID": "20261014T180000-123",
        }
        self.env.pop("FORGE_RUN_LOG", None)
        self.logs = self.root / "logs"

    def command(self, script, *args, env=None):
        return subprocess.run(
            ["bash", str(script), *map(str, args)],
            capture_output=True, text=True, env=env or self.env, check=False,
        )

    def open_run(self, run_id="20261014T180000-123", keep="8"):
        env = {**self.env, "FORGE_RUN_ID": run_id}
        result = self.command(INIT, self.logs, keep, "run", run_id, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        path = Path(result.stdout.strip())
        self.assertTrue(path.is_file())
        return path

    def test_host_logs_rotate_with_retention_and_preserve_old_content(self):
        host = self.logs / "bv.deulos.com" / "host"
        host.mkdir(parents=True)
        (host / "common.log").write_text("legacy host output\n", encoding="utf-8")
        (host / "error.log").write_text("legacy failure\n", encoding="utf-8")

        for number in range(3):
            result = self.command(INIT, self.logs, "2", "host", "bv.deulos.com")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(host / "common.log"))
            self.assertIn("event=log_open scope=host",
                          (host / "common.log").read_text())
            event = self.command(
                WRITE, host / "common.log", "ERROR", "test_error",
                f"sequence={number}",
                env={**self.env, "FORGE_ERROR_LOG": str(host / "error.log")},
            )
            self.assertEqual(event.returncode, 0, event.stderr)
            self.assertIn(f"sequence={number}", (host / "error.log").read_text())

            common_archives = list(host.glob("common_[0-9]*.log"))
            error_archives = list(host.glob("error_[0-9]*.log"))
            self.assertEqual(len(common_archives), min(number + 1, 1))
            self.assertEqual(len(error_archives), min(number + 1, 1))
            for log in (host / "common.log", host / "error.log"):
                self.assertEqual(log.stat().st_mode & 0o777, 0o640)

        self.assertFalse(any("legacy host output" in p.read_text()
                             for p in host.glob("common_[0-9]*.log")))
        self.assertFalse(any("legacy failure" in p.read_text()
                             for p in host.glob("error_[0-9]*.log")))
        self.assertIn("sequence=1", next(host.glob("error_[0-9]*.log")).read_text())
        self.assertIn("sequence=2", (host / "error.log").read_text())

    def test_first_host_log_initialization_and_keep_one(self):
        host = self.logs / "bv.deulos.com" / "host"
        for number in range(2):
            result = self.command(INIT, self.logs, "1", "host", "bv.deulos.com")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(host / "common.log"))
            self.assertTrue((host / "error.log").is_file())
            self.assertEqual(list(host.glob("common_[0-9]*.log")), [])
            self.assertEqual(list(host.glob("error_[0-9]*.log")), [])

    def test_run_log_initialization_retention_and_no_overwrite(self):
        first = self.open_run("20261014T180000-123", keep="2")
        first.write_text("previous complete run\n", encoding="utf-8")
        duplicate = self.command(
            INIT, self.logs, "2", "run", "20261014T180000-123",
        )
        self.assertNotEqual(duplicate.returncode, 0)
        self.assertEqual(first.read_text(), "previous complete run\n")

        second = self.open_run("20261014T180100-123", keep="2")
        third = self.open_run("20261014T180200-123", keep="2")
        self.assertFalse(first.exists())
        self.assertTrue(second.exists())
        self.assertTrue(third.exists())
        self.assertEqual(sorted(p.name for p in third.parent.glob("*.log")),
                         [second.name, third.name])

    def test_structured_records_are_mirrored_without_duplication(self):
        run = self.open_run()
        target = self.root / "target.log"
        target.touch()
        env = {**self.env, "FORGE_RUN_LOG": str(run)}
        result = self.command(
            WRITE, target, "ERROR", "stage_end", "stage=os", "exit_code=42",
            env=env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(run.read_text(), target.read_text())
        self.assertIn("level=ERROR event=stage_end", run.read_text())

        # Writing directly to the run log must not record the event twice.
        result = self.command(WRITE, run, "INFO", "run_end", "exit_code=42", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(run.read_text().count("event=run_end"), 1)

    def test_stage_capture_mirrors_sanitized_output_and_original_exit(self):
        run = self.open_run()
        target = self.root / "target.log"
        target.touch()
        env = {**self.env, "FORGE_RUN_LOG": str(run)}
        producer = (
            'import sys; '
            'sys.stdout.write("progress 1\\rprogress 2\\n"); '
            'sys.stderr.write("error from producer\\n"); '
            'sys.stdout.write("\\x1b[31mcoloured\\x1b[0m\\n"); '
            'sys.exit(23)'
        )
        result = self.command(
            CAPTURE, target, "os", "--", "python3", "-c", producer, env=env,
        )
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertIn("coloured", result.stdout)
        self.assertIn("\x1b[31m", result.stdout)
        for path in (run, target):
            content = path.read_text()
            self.assertIn("progress 2\n", content)
            self.assertNotIn("progress 1", content)
            self.assertIn("error from producer\n", content)
            self.assertIn("coloured\n", content)
            self.assertNotIn("\x1b[", content)
            self.assertEqual(content.count("event=stage_start"), 1)
            self.assertEqual(content.count("event=stage_end"), 1)
            self.assertEqual(content.count("error from producer"), 1)
        self.assertEqual(run.read_text(), target.read_text())

    def test_stage_output_is_streamed_before_producer_finishes(self):
        import select
        import time

        run = self.open_run()
        target = self.root / "target.log"
        target.touch()
        release = self.root / "release"
        producer = (
            "import pathlib,sys,time; "
            "release=pathlib.Path(sys.argv[1]); "
            "print('streamed-before-release',flush=True); "
            "deadline=time.monotonic()+10; "
            "exec('while not release.exists() and time.monotonic()<deadline: time.sleep(0.01)'); "
            "print('streamed-after-release',flush=True)"
        )
        process = subprocess.Popen(
            ["bash", str(CAPTURE), str(target), "backup", "--",
             "python3", "-u", "-c", producer, str(release)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1,
            env={**self.env, "FORGE_RUN_LOG": str(run)},
        )
        try:
            observed = b""
            deadline = time.monotonic() + 3
            while b"streamed-before-release\n" not in observed:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                ready, _, _ = select.select([process.stdout.fileno()], [], [], remaining)
                if not ready:
                    break
                part = os.read(process.stdout.fileno(), 4096)
                if not part:
                    break
                observed += part
            self.assertIn(b"stage=start name=backup\n", observed)
            self.assertIn(b"streamed-before-release\n", observed,
                          "producer output was buffered until process exit")
            deadline = time.monotonic() + 3
            while (b"streamed-before-release\n" not in target.read_bytes()
                   or b"streamed-before-release\n" not in run.read_bytes()):
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.01)
            for path in (target, run):
                self.assertIn(b"streamed-before-release\n", path.read_bytes(),
                              f"{path} did not log progress before producer exit")
            self.assertIsNone(process.poll(), "producer finished before streaming check")
        finally:
            release.touch()
            stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertIn("streamed-after-release", stdout)
        for path in (target, run):
            self.assertIn("streamed-before-release", path.read_text())
            self.assertIn("streamed-after-release", path.read_text())

    def test_terminal_scrollback_and_log_sanitization_across_chunks(self):
        run = self.open_run()
        target = self.root / "target.log"
        target.touch()
        producer = (
            'import os,time; '
            'os.write(1,b"before\\n\\x1b[3"); '
            'time.sleep(0.05); '
            'os.write(1,b"J\\x1b[32mcolor\\x1b[0m\\n"); '
            'os.write(1,b"loading 10%\\rloading 95%\\n"); '
            'os.write(1,b"\\x1b]0;secret title\\x07after\\n")'
        )
        # Inspect raw bytes: text=True normalizes carriage returns to newlines.
        result = subprocess.run(
            ["bash", str(CAPTURE), str(target), "backup", "--",
             "python3", "-u", "-c", producer],
            capture_output=True, check=False,
            env={**self.env, "FORGE_RUN_LOG": str(run)},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"before\n", result.stdout)
        self.assertIn(b"\x1b[32mcolor\x1b[0m", result.stdout)
        self.assertIn(b"loading 10%\rloading 95%", result.stdout)
        self.assertNotIn(b"\x1b[3J", result.stdout)
        for path in (target, run):
            logged = path.read_text()
            self.assertIn("before\ncolor\nloading 95%\nafter\n", logged)
            self.assertNotIn("loading 10%", logged)
            self.assertNotIn("secret title", logged)
            self.assertNotIn("\x1b", logged)
        self.assertEqual(target.read_bytes(), run.read_bytes())

    def test_final_table_is_plain_in_log_and_unchanged_on_terminal(self):
        run = self.open_run()
        record = (
            "result_target type=lxc vmid=101 name=pihole selected=true "
            "attempted=true status=OK reason=completed apt_upgraded=0 "
            "app_before=- app_after=- app_repository=- failed_stage=- "
            "recovery=- result_detail=OK\n"
        )
        result = subprocess.run(
            ["python3", str(TABLE)],
            input=record, capture_output=True, text=True, check=False,
            env={**self.env, "FORGE_RUN_LOG": str(run),
                 "FORGE_TABLE_WIDTH": "110", "FORGE_TABLE_COLOR": "always"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("\x1b[32m", result.stdout)
        logged = run.read_text()
        self.assertNotIn("\x1b[", logged)
        for output in (logged, result.stdout):
            self.assertEqual(output.count("Forge final results"), 1)
            self.assertEqual(output.count("result_global status=SUCCESS"), 1)
            self.assertIn("101", output)

    def test_preflight_failure_is_recorded_before_target_logging(self):
        run = self.open_run()
        env = {**self.env, "FORGE_RUN_LOG": str(run)}
        result = self.command(
            ROOT / "lib/workflows/update-all.sh", "invalid", env=env,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported update mode", result.stderr)
        logged = run.read_text()
        self.assertIn("level=ERROR event=run_error", logged)
        self.assertIn("unsupported", logged)

    def test_cli_run_start_end_and_original_failure_code(self):
        # Copy only the real public CLI/config/runtime/logging entrypoint, and
        # replace the sole update target with an inert failing test double.
        sandbox = self.root / "forge-root"
        parts = [
            "forge", "forge.conf.default", "lib/config/get.sh",
            "lib/config/load.sh", "lib/config/validate.sh",
            "lib/runtime/require-context.sh", "lib/runtime/persistent.sh",
            "lib/runtime/persistent-worker.sh", "lib/logging/init.sh",
            "lib/logging/write.sh",
        ]
        for part in parts:
            dst = sandbox / part
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / part, dst)
        cli = sandbox / "forge"
        cli.write_text(cli.read_text().replace(
            'LOCK_FILE="/run/lock/proxmox-forge.lock"',
            f'LOCK_FILE="{self.root / "forge.lock"}"'), encoding="utf-8")
        host = sandbox / "lib/host/update.sh"
        host.parent.mkdir(parents=True, exist_ok=True)
        host.write_text('#!/bin/bash\nprintf "fake update ran\\n"\nexit 37\n',
                        encoding="utf-8")
        (sandbox / "forge.conf").write_text(
            f'LOG_DIR="{self.logs}"\n', encoding="utf-8")
        result = subprocess.run(
            ["bash", str(cli), "host", "update"],
            capture_output=True, text=True, check=False,
            env=self.env, cwd=sandbox,
        )
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertIn("fake update ran", result.stdout)
        run_logs = list(self.logs.glob("*/runs/*.log"))
        self.assertEqual(len(run_logs), 1, run_logs)
        logged = run_logs[0].read_text()
        self.assertEqual(logged.count("event=run_start"), 1)
        self.assertEqual(logged.count("event=run_end"), 1)
        self.assertIn("exit_code=37", logged)
        self.assertRegex(logged, r"event=run_end .*duration_seconds=[0-9]+")
        self.assertRegex(result.stdout, r"Forge run duration: (?:[0-9]+ h [0-9]+ m |[0-9]+ m )?[0-9]+ s")
        self.assertEqual((self.root / "forge.lock").read_text(), "")


if __name__ == "__main__":
    unittest.main()
