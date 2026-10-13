#!/usr/bin/env python3
"""F224 host integration: real host orchestrator with isolated, nonmutating helpers."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]

CAPTURE = r"""#!/bin/bash
log="$1"; stage="$2"; shift 3
printf '2026 level=INFO event=stage_start stage=%s command=fake\n' "$stage" >> "$log"
output="$("$@" 2>&1)"
status=$?
if [[ -n "$output" ]]; then
  printf '%s\n' "$output" | tee -a "$log"
fi
printf '2026 level=INFO event=stage_end stage=%s status=%s exit_code=%s\n' \
  "$stage" "$([[ "$status" == 0 ]] && echo success || echo failed)" "$status" >> "$log"
exit "$status"
"""

HELPER = r"""#!/bin/bash
case "$(basename "$0")" in
  init.sh) touch "$FORGE_TEST_LOG"; printf '%s\n' "$FORGE_TEST_LOG" ;;
  write.sh) : ;;
  check-requirements.sh) : ;;
  create.sh) printf '%s\n' 'backup=success type=host path=/tmp/mock.tgz' ;;
  os.sh)
    if [[ "$FORGE_TEST_OS_FAILURE" == true ]]; then
      printf 'ERROR: actual package dependency failure\n' >&2
      exit 42
    fi
    ;;
  held-packages.sh)
    if [[ "$FORGE_TEST_HELD_FAILURE" == true ]]; then
      printf 'ERROR: unrelated held-package query failed\n' >&2
      exit 7
    fi
    ;;
  reboot-required.sh)
    if [[ "$FORGE_TEST_REBOOT_FAILURE" == true ]]; then exit 9; fi
    printf 'reboot_required=no type=host marker=no\n'
    ;;
  *) exit 95 ;;
esac
"""


class HostResultDetailsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="forge-f224-host-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.lib = self.root / "lib"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        host = "host-test.example"
        error_log = self.root / host / "host" / "error.log"
        error_log.parent.mkdir(parents=True)
        error_log.touch()
        (self.bin / "hostname").write_text('#!/bin/sh\nprintf "host-test.example\\n"\n')
        (self.bin / "hostname").chmod(0o755)

        paths = [
            "host/update.sh", "host/check-requirements.sh",
            "backup/host/create.sh", "host/update/os.sh",
            "preflight/held-packages.sh", "postflight/reboot-required.sh",
            "logging/init.sh", "logging/capture.sh", "logging/write.sh",
            "results/record.sh", "results/table.py", "results/apt.sh", "config/get.sh",
        ]
        for path in paths:
            dest = self.lib / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            if path in ("host/update.sh", "results/record.sh", "results/table.py"):
                dest.symlink_to(ROOT / "lib" / path)
            elif path == "logging/capture.sh":
                dest.write_text(CAPTURE, encoding="utf-8")
            elif path == "results/apt.sh":
                dest.write_text(
                    'FORGE_APT_COUNT="-"; FORGE_APT_ACTIVE=false\n'
                    'forge_apt_cleanup() { :; }\n'
                    'forge_apt_begin() { :; }\n'
                    'forge_apt_finalize() { FORGE_APT_COUNT=0; }\n',
                )
            elif path == "config/get.sh":
                dest.write_text(
                    'config_get() {\n'
                    '  declare -gA CONFIG=(\n'
                    '    [UPDATE_HOST]=true\n'
                    '    [EMAIL_NOTIFICATIONS]="${FORGE_TEST_EMAIL_NOTIFICATIONS:-false}"\n'
                    '    [NOTIFY_ONLY_ERRORS]="${FORGE_TEST_NOTIFY_ONLY_ERRORS:-true}"\n'
                    '    [LOG_DIR]="$FORGE_TEST_LOG_DIR"\n'
                    '    [LOG_KEEP]=5\n'
                    '    [CREATE_BACKUP_BEFORE_HOST_UPDATE]=false\n'
                    '    [HEALTH_CHECK]=true\n'
                    '  )\n'
                    '}\n',
                )
            else:
                dest.write_text(HELPER, encoding="utf-8")
        guard = self.root / "guard.sh"
        guard.write_text("#!/bin/sh\nexit 0\n")
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "FORGE_RUNTIME_GUARD": str(guard),
            "FORGE_TEST_LOG_DIR": str(self.root),
            "FORGE_TEST_LOG": str(self.root / "host-update.log"),
            "FORGE_TEST_OS_FAILURE": "false",
            "FORGE_TEST_HELD_FAILURE": "false",
            "FORGE_TEST_REBOOT_FAILURE": "false",
        }

    def invoke(self, **updates):
        result = subprocess.run(
            ["bash", str(self.lib / "host/update.sh")],
            env={**self.env, **updates}, capture_output=True,
            text=True, check=False,
        )
        lines = [x for x in result.stdout.splitlines() if x.startswith("result_target ")]
        self.assertEqual(len(lines), 1, result.stdout + result.stderr)
        row = dict(part.split("=", 1) for part in lines[0].split()[1:])
        return result, row, unquote(row["result_detail"])

    def test_primary_os_error_uses_own_stage_not_later_held_warning(self):
        result, row, detail = self.invoke(
            FORGE_TEST_OS_FAILURE="true", FORGE_TEST_HELD_FAILURE="true",
        )
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(row["status"], "ERROR")
        self.assertEqual(row["exit_code"], "42")
        self.assertEqual(row["failed_stage"], "os_update")
        self.assertEqual(row["recovery"], "-")
        self.assertIn(
            "ERROR: os_update (exit 42): actual package dependency failure",
            detail,
        )
        self.assertIn("WARNING: held-package inspection failed (exit 7)", detail)
        self.assertNotIn("unrelated held-package query failed", detail)
        self.assertNotIn("result_target ", result.stderr)

    def test_nonfatal_reboot_and_held_warnings_leave_success(self):
        result, row, detail = self.invoke(
            FORGE_TEST_HELD_FAILURE="true", FORGE_TEST_REBOOT_FAILURE="true",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(row["status"], "OK")
        self.assertEqual(row["failed_stage"], "-")
        self.assertEqual(
            detail,
            "OK; WARNING: held-package inspection failed (exit 7); "
            "reboot requirement unknown (check exit 9)",
        )


    def test_f153_individual_host_sends_one_failure_mail_when_opted_in(self):
        sender = self.bin / "sendmail"
        sender.write_text('#!/bin/sh\ncat > "$FORGE_TEST_MAIL_LOG"\n', encoding="utf-8")
        sender.chmod(0o755)
        mail = self.root / "host-mail.txt"
        enabled = {"FORGE_TEST_EMAIL_NOTIFICATIONS": "true",
                   "FORGE_TEST_MAIL_LOG": str(mail)}
        success, _, _ = self.invoke(**enabled)
        self.assertEqual(success.returncode, 0, success.stderr)
        self.assertFalse(mail.exists(), "errors-only sent a success message")
        failed, _, _ = self.invoke(FORGE_TEST_OS_FAILURE="true", **enabled)
        self.assertEqual(failed.returncode, 42, failed.stderr)
        content = mail.read_text(encoding="utf-8")
        self.assertIn("To: root\\n", content)
        self.assertIn("Subject: [Proxmox Forge] FAILED", content)
        self.assertIn("ERROR: os_update (exit 42): actual package dependency failure",
                      content)
        self.assertEqual(failed.stdout.count("Forge final results"), 1)

    def test_f225_host_success_and_failure_have_one_table(self):
        for failed, expected_status, code in [
            ("false", "OK", 0), ("true", "ERROR", 42),
        ]:
            with self.subTest(failed=failed):
                result, row, detail = self.invoke(FORGE_TEST_OS_FAILURE=failed)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(row["status"], expected_status)
                self.assertEqual(result.stdout.count("Forge final results"), 1)
                self.assertIn("HOST | host-test.example | 0 | —", result.stdout)
                self.assertIn("Totals: targets=1 selected=1 attempted=1", result.stdout)
                self.assertIn(f"ERROR={int(bool(code))} ", result.stdout)
                global_status = "FAILED" if code else "SUCCESS"
                self.assertIn(
                    f"result_global status={global_status} targets=1 selected=1 "
                    f"attempted=1 succeeded={int(not bool(code))} failed={int(bool(code))} "
                    "skipped=0 not_run=0",
                    result.stdout,
                )
                self.assertEqual(result.stdout.count("result_global "), 1)

    def test_bulk_mode_does_not_duplicate_host_target_record(self):
        handoff = self.root / "host-handoff"
        result = subprocess.run(
            ["bash", str(self.lib / "host/update.sh")],
            env={**self.env, "FORGE_RESULTS_AGGREGATE": "bulk",
                 "FORGE_RESULT_DETAIL_FILE": str(handoff)},
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("result_target ", result.stdout)
        self.assertNotIn("Forge final results", result.stdout)
        fields = handoff.read_text().rstrip("\n").split("\t")
        self.assertEqual(fields, ["OK", "-", "-"])


if __name__ == "__main__":
    unittest.main()
