#!/usr/bin/env python3
"""Compact console UI: synthetic progress, warnings, and real CLI exit codes."""

import os
import pty
import select
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRESENTER = ROOT / "lib/ui/progress.py"


def run_presenter(text, mode="bulk", target="all"):
    return subprocess.run(
        ["python3", "-u", str(PRESENTER), mode, target],
        input=text, capture_output=True, text=True, check=False,
        env={**os.environ, "FORGE_RUN_ID": "20261106T185000-100",
             "FORGE_LANGUAGE": "es"},
    )


def read_pty(master):
    output = bytearray()
    while True:
        ready, _, _ = select.select([master], [], [], 0.1)
        if not ready:
            break
        try:
            part = os.read(master, 65536)
        except OSError:
            break
        if not part:
            break
        output.extend(part)
    return bytes(output).decode("utf-8", "replace")


class CompactProgressTests(unittest.TestCase):
    def test_bulk_progress_filters_package_chatter_and_keeps_results(self):
        input_text = (
            "space=ok target=100 free_kb=11111 minimum_mb=1024\n"
            "update_all=start mode=all update_host=true update_running_lxc=true lxc_targets=2\n"
            "update_all_stage=start stage=host\n"
            "stage=start name=os_update\n"
            "Reading package lists...\n"
            "apt package installed\n"
            "update_all_stage=success stage=host exit_code=0\n"
            "update_all_target=start vmid=100\n"
            "type=lxc vmid=100 name=wireguard state=running\n"
            "stage=start name=backup\n"
            "INFO: archive file size: 12GB\n"
            "update_all_target=success vmid=100 exit_code=0\n"
            "update_all_target=start vmid=101\n"
            "type=lxc vmid=101 name=pihole state=running\n"
            "stage=start name=health\n"
            "update_all_target=success vmid=101 exit_code=0\n"
            "result_global status=SUCCESS targets=3 succeeded=3 failed=0 skipped=0\n"
        )
        result = run_presenter(input_text)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Host Proxmox OK", result.stdout)
        self.assertIn("100 · wireguard OK", result.stdout)
        self.assertIn("101 · pihole OK", result.stdout)
        self.assertIn("resultado SUCCESS", result.stdout)
        self.assertIn("forge history 20261106T185000-100", result.stdout)
        self.assertNotIn("Reading package lists", result.stdout)
        self.assertNotIn("archive file size", result.stdout)
        self.assertNotIn("space=ok", result.stdout)

    def test_failed_target_and_held_packages_warning_are_visible(self):
        lines = (
            "update_all=start mode=lxc update_host=false update_running_lxc=true lxc_targets=1\n"
            "update_all_target=start vmid=103\n"
            "type=lxc vmid=103 name=seafile state=running\n"
            "stage=start name=os_update\n"
            "WARNING: 3 explicitly held APT package(s) have newer candidate versions\n"
            "ERROR: package manager failed\n"
            "update_all_target=failed vmid=103 exit_code=42\n"
            "result_target type=lxc vmid=103 name=seafile selected=true attempted=true "
            "status=ERROR reason=update_failed exit_code=42 failed_stage=os_update "
            "result_detail=ERROR%3A%20os_update%20%28exit%2042%29\n"
            "result_global status=FAILED targets=1 succeeded=0 failed=1 skipped=0\n"
        )
        result = run_presenter(lines)
        self.assertEqual(result.returncode, 0, result.stderr)
        for message in ("seafile ERROR", "exit 42", "3 explicitly held",
                        "package manager failed", "resultado FAILED"):
            self.assertIn(message, result.stdout)

    def test_final_table_survives_compact_mode_without_losing_columns(self):
        table = (
            "Resultados finales de Forge\n"
            "VMID | Nombre     | APT | Versión software   | Cambios | Resultado\n"
            "-----+------------+-----+--------------------+---------+----------------\n"
            "101  | pihole     | 2   | v6.4.3 → v6.4.4   | [1]     | OK\n"
            "105  | caddy      | 0   | v2.11.6           | [2]     | ERROR: health\n"
            "\n"
            "Enlaces del historial de cambios:\n"
            "  [1] Cambios: https://github.com/pi-hole/pi-hole\n"
            "  [2] Cambios: https://github.com/caddyserver/caddy\n"
            "Totales: targets=2 selected=2 attempted=2 OK=1 ERROR=1 SKIPPED=0 NOT_RUN=0\n"
            "result_global status=PARTIAL targets=2 selected=2 attempted=2 succeeded=1 failed=1 skipped=0 not_run=0\n"
            "Resultado global: PARTIAL\n"
            "\n"
            "Objetivos fallidos o bloqueados (1):\n"
            "  105 | caddy | ERROR\n"
            "    Detalle: ERROR: health (exit 1); recovery succeeded\n"
        )
        result = run_presenter(
            "update_all=start mode=selected update_host=false lxc_targets=2\n"
            "update_all_target=start vmid=101\n"
            "stage=start name=os_update\n"
            "Reading package lists (must remain hidden)\n"
            "update_all_target=success vmid=101 exit_code=0\n"
            "update_all_target=start vmid=105\n"
            "stage=start name=health\n"
            "update_all_target=failed vmid=105 exit_code=1\n"
            + table
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(table, result.stdout)
        self.assertEqual(result.stdout.count("Resultados finales de Forge"), 1)
        self.assertLess(
            result.stdout.index("forge history 20261106T185000-100"),
            result.stdout.index("Resultados finales de Forge"),
        )
        self.assertNotIn("Reading package lists", result.stdout)

    def test_terminal_keeps_final_table_after_dashboard(self):
        master, slave = pty.openpty()
        try:
            process = subprocess.Popen(
                ["python3", "-u", str(PRESENTER), "bulk", "selected"],
                stdin=subprocess.PIPE, stdout=slave, stderr=subprocess.PIPE,
                env={**os.environ, "TERM": "xterm-256color", "FORGE_LANGUAGE": "es"},
            )
            os.close(slave)
            slave = -1
            process.stdin.write(
                b"update_all=start mode=selected update_host=false lxc_targets=1\n"
                b"update_all_target=start vmid=101\n"
                b"stage=start name=health\n"
                b"update_all_target=success vmid=101 exit_code=0\n"
                b"Resultados finales de Forge\n"
                b"VMID | Nombre | Resultado\n"
                b"101  | pihole | OK\n"
                b"result_global status=SUCCESS targets=1 succeeded=1 failed=0\n"
                b"Resultado global: SUCCESS\n"
            )
            process.stdin.close()
            self.assertEqual(process.wait(timeout=10), 0, process.stderr.read().decode())
            output = read_pty(master)
            self.assertIn("Resultados finales de Forge", output)
            self.assertIn("101  | pihole | OK", output)
            self.assertIn("Resultado global: SUCCESS", output)
            self.assertIn("100%", output)
        finally:
            if slave >= 0:
                os.close(slave)
            os.close(master)

    def test_terminal_draws_live_dashboard_in_place(self):
        master, slave = pty.openpty()
        try:
            p = subprocess.Popen(
                ["python3", "-u", str(PRESENTER), "bulk", "all"],
                stdin=subprocess.PIPE, stdout=slave, stderr=subprocess.PIPE,
                env={**os.environ, "TERM": "xterm-256color",
                     "FORGE_LANGUAGE": "es"},
            )
            os.close(slave)
            slave = -1
            p.stdin.write(b"update_all=start mode=all update_host=true lxc_targets=1\n")
            p.stdin.write(b"update_all_stage=start stage=host\nstage=start name=backup\n")
            p.stdin.flush()
            ready, _, _ = select.select([master], [], [], 3)
            self.assertTrue(ready, "progress must reach terminal before stage ends")
            first = os.read(master, 65536)
            self.assertIn(b"Forge", first)
            p.stdin.write(b"update_all_stage=success stage=host exit_code=0\n")
            p.stdin.write(b"update_all_target=start vmid=100\n")
            p.stdin.write(b"type=lxc vmid=100 name=wireguard state=running\n")
            p.stdin.write(b"update_all_target=success vmid=100 exit_code=0\n")
            p.stdin.write(b"result_global status=SUCCESS targets=2 succeeded=2 failed=0\n")
            p.stdin.close()
            self.assertEqual(p.wait(timeout=10), 0, p.stderr.read().decode())
            output = first + read_pty(master).encode()
            self.assertIn(b"\x1b[", output)
            self.assertIn(b"100%", output)
            self.assertIn(b"SUCCESS", output)
        finally:
            if slave >= 0:
                os.close(slave)
            os.close(master)

    def test_public_cli_compact_mode_keeps_underlying_exit_code(self):
        with tempfile.TemporaryDirectory(prefix="forge-compact-") as tmp:
            base = Path(tmp)
            sandbox = base / "forge-root"
            parts = (
                "forge", "forge.conf.default", "lib/config/get.sh",
                "lib/config/load.sh", "lib/config/validate.sh",
                "lib/runtime/require-context.sh", "lib/runtime/persistent.sh",
                "lib/runtime/persistent-worker.sh", "lib/logging/init.sh",
                "lib/i18n/translate.py", "lib/i18n/en.json", "lib/i18n/es.json",
                "lib/logging/write.sh", "lib/ui/progress.py",
            )
            for part in parts:
                dst = sandbox / part
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / part, dst)
            cli = sandbox / "forge"
            cli.write_text(cli.read_text().replace(
                'LOCK_FILE="/run/lock/proxmox-forge.lock"',
                f'LOCK_FILE="{base / "forge.lock"}"'), encoding="utf-8")
            host = sandbox / "lib/host/update.sh"
            host.parent.mkdir(parents=True, exist_ok=True)
            host.write_text(
                '#!/bin/bash\n'
                'printf "stage=start name=os_update\\n"\n'
                'printf "internal package output must stay hidden\\n"\n'
                'printf "ERROR: deliberate failure\\n"\n'
                'printf "update=failed type=host exit_code=37\\n"\n'
                'exit 37\n', encoding="utf-8",
            )
            logs = base / "logs"
            (sandbox / "forge.conf").write_text(
                f'LOG_DIR="{logs}"\n'
                'PERSISTENT_UPDATE_SESSION=false\n'
                'CHECK_FORGE_UPDATES_BEFORE_UPDATE=false\n', encoding="utf-8",
            )
            bin_dir = base / "bin"
            bin_dir.mkdir()
            hostname = bin_dir / "hostname"
            hostname.write_text('#!/bin/sh\nprintf "bv.deulos.com\\n"\n')
            hostname.chmod(0o755)
            env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}",
                   "FORGE_OUTPUT_MODE": "compact"}

            master, slave = pty.openpty()
            try:
                p = subprocess.Popen(
                    ["bash", str(cli), "host", "update"],
                    stdin=subprocess.DEVNULL, stdout=slave, stderr=slave,
                    env=env, cwd=sandbox,
                )
                os.close(slave)
                slave = -1
                self.assertEqual(p.wait(timeout=15), 37)
                output = read_pty(master)
            finally:
                if slave >= 0:
                    os.close(slave)
                os.close(master)
            self.assertIn("ERROR: deliberate failure", output)
            self.assertIn("Forge run duration:", output)
            self.assertNotIn("internal package output must stay hidden", output)
            run_logs = list(logs.glob("*/runs/*.log"))
            self.assertEqual(len(run_logs), 1)
            self.assertIn("exit_code=37", run_logs[0].read_text())


if __name__ == "__main__":
    unittest.main()
