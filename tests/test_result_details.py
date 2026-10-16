#!/usr/bin/env python3
"""F224: real result formatting, error provenance and defensive encoding."""

import subprocess
import tempfile
import unittest
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "lib/results/record.sh"


class ActionableResultTests(unittest.TestCase):
    def run_helper(self, commands):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; ' + commands, "_", str(HELPER)],
            capture_output=True, text=True, check=False,
        )

    def result(self, type_, status, reason, exit_code="", stage="-", error="",
               recovery="-", warning=""):
        return self.run_helper(
            "forge_result_publish " +
            " ".join(
                "'" + x.replace("'", "'\\''") + "'" for x in (
                    type_, "HOST" if type_ == "host" else "101", "hostname",
                    "true", "true", status, reason, exit_code,
                    "-", "-", "-", "-", stage, error, recovery, warning,
                )
            )
        )

    def parse(self, process):
        self.assertEqual(process.returncode, 0, process.stderr)
        line = process.stdout.strip()
        self.assertTrue(line.startswith("result_target "), line)
        row = dict(field.split("=", 1) for field in line.split()[1:])
        self.assertEqual(len(row), 15 if row["status"] == "ERROR" else 14)
        return row, unquote(row["result_detail"])

    def test_success_and_warning_are_not_misrepresented_as_error(self):
        row, detail = self.parse(self.result("lxc", "OK", "completed", warning="fstrim failed (exit 21)"))
        self.assertEqual(row["status"], "OK")
        self.assertEqual(detail, "OK; WARNING: fstrim failed (exit 21)")

    def test_all_known_skip_and_not_run_descriptions(self):
        cases = [
            ("SKIPPED", "template", "SKIPPED: container is a template"),
            ("SKIPPED", "stopped", "SKIPPED: container is stopped"),
            ("SKIPPED", "excluded", "SKIPPED: excluded by configuration"),
            ("SKIPPED", "host_disabled", "SKIPPED: host updates disabled"),
            ("SKIPPED", "running_lxc_disabled", "SKIPPED: running LXC updates disabled"),
            ("NOT_RUN", "host_update_failed", "NOT RUN: host update failed"),
            ("NOT_RUN", "preflight_blocked", "NOT RUN: preflight blocked the update"),
        ]
        for status, reason, expected in cases:
            with self.subTest(status=status, reason=reason):
                _, detail = self.parse(self.result("lxc", status, reason))
                self.assertEqual(detail, expected)

    def test_known_stage_code_explicit_error_and_recovery_remain_distinct(self):
        row, detail = self.parse(self.result(
            "lxc", "ERROR", "update_failed", "42", "application_update",
            "Cannot install package: post-install hook failed",
            "failed:19", "guest state restoration failed (exit 20)",
        ))
        self.assertEqual(row["exit_code"], "42")
        self.assertEqual(row["failed_stage"], "application_update")
        self.assertEqual(row["recovery"], "failed:19")
        self.assertEqual(
            detail,
            "ERROR: application_update (exit 42): Cannot install package: post-install hook failed"
            "; recovery failed (exit 19); WARNING: guest state restoration failed (exit 20)",
        )

    def test_failure_without_explicit_error_does_not_invent_a_cause(self):
        row, detail = self.parse(self.result("host", "ERROR", "update_failed", "8", "backup"))
        self.assertEqual(detail, "ERROR: backup (exit 8)")
        self.assertEqual(row["recovery"], "-")

    def test_percent_encoding_prevents_multiline_or_field_injection(self):
        row, detail = self.parse(self.result(
            "lxc", "ERROR", "update_failed", "9", "os_update",
            "OSError: inválido\nstatus=OK injected field", "-",
        ))
        self.assertIn("inválido\nstatus=OK injected field", detail)
        self.assertEqual(row["status"], "ERROR")
        self.assertEqual(row["exit_code"], "9")
        self.assertNotIn("\n", row["result_detail"])
        self.assertIn("%0A", row["result_detail"])

    def test_explicit_error_from_only_failed_stage_not_unrelated_stage(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "log.txt"
            log.write_text(
                "2026 level=INFO event=stage_start stage=os_update command=update\n"
                "ERROR: Package cache is inaccessible\n"
                "2026 level=ERROR event=stage_end stage=os_update status=failed exit_code=42\n"
                "2026 level=INFO event=stage_start stage=held_packages command=held\n"
                "ERROR: Cannot inspect held packages\n"
                "2026 level=INFO event=stage_end stage=held_packages status=success exit_code=0\n"
                "2026 level=WARN event=recovery_start vmid=101\n"
                "2026 level=INFO event=stage_start stage=recovery_health command=health\n"
                "ERROR: Recovery health error\n"
                "2026 level=ERROR event=stage_end stage=recovery_health status=failed exit_code=2\n",
                encoding="utf-8",
            )
            r = self.run_helper(
                f"forge_result_stage_error '{log}' os_update"
            )
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.strip(), "ERROR: Package cache is inaccessible")
            r = self.run_helper(
                f"forge_result_stage_error '{log}' held_packages"
            )
            self.assertEqual(r.stdout.strip(), "ERROR: Cannot inspect held packages")
            r = self.run_helper(
                f"forge_result_stage_error '{log}' unknown_stage"
            )
            self.assertEqual(r.stdout.strip(), "")

    def test_multiline_community_scripts_error_is_verbatim_and_stage_scoped(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "stage.log"
            diagnostics = [
                "npm ERR! code ERESOLVE",
                "npm ERR! unable to resolve dependency tree",
                "npm ERR! Conflicting peer dependency: example@1.2",
            ]
            log.write_text(
                "2026 level=INFO event=stage_start stage=os_update command=apt\\n"
                "ERROR: failure from unrelated earlier stage\\n"
                "2026 level=ERROR event=stage_end stage=os_update status=failed exit_code=1\\n"
                "2026 level=INFO event=stage_start stage=application_update command=helper\\n"
                "Downloading app...\\n"
                + "\\n".join(diagnostics) + "\\n"
                "This line does not explicitly report an error\\n"
                "2026 level=ERROR event=stage_end stage=application_update status=failed exit_code=42\\n"
                "2026 level=INFO event=stage_start stage=recovery_health command=check\\n"
                "ERROR: rollback health failure must not leak\\n"
                "2026 level=ERROR event=stage_end stage=recovery_health status=failed exit_code=8\\n",
                encoding="utf-8",
            )
            extracted = self.run_helper(
                f"forge_result_stage_error '{log}' application_update"
            )
            self.assertEqual(extracted.returncode, 0, extracted.stderr)
            self.assertEqual(extracted.stdout.splitlines(), diagnostics)

            row, detail = self.parse(self.result(
                "lxc", "ERROR", "update_failed", "42", "application_update",
                extracted.stdout.rstrip("\\n"), "success",
            ))
            self.assertEqual(row["exit_code"], "42")
            self.assertEqual(row["recovery"], "success")
            self.assertIn("Failed stage output:\\n" + "\\n".join(diagnostics), detail)
            self.assertTrue(detail.endswith("\\nrecovery succeeded"), detail)
            self.assertNotIn("unrelated earlier stage", detail)
            self.assertNotIn("rollback health failure", detail)

    def test_verbose_failure_keeps_first_and_last_bounded_diagnostic_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "stage.log"
            diagnostic_lines = [f"npm ERR! original-error-{i}" for i in range(1, 17)]
            log.write_text(
                "2026 level=INFO event=stage_start stage=application_update command=helper\\n"
                + "\\n".join(diagnostic_lines) + "\\n"
                "2026 level=ERROR event=stage_end stage=application_update status=failed exit_code=1\\n",
                encoding="utf-8",
            )
            result = self.run_helper(
                f"forge_result_stage_error '{log}' application_update"
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [
                *diagnostic_lines[:4],
                "[4 diagnostic lines omitted; see log]",
                *diagnostic_lines[8:],
            ])

    def test_failed_stage_without_explicit_diagnostic_adds_no_guessed_cause(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "stage.log"
            log.write_text(
                "2026 level=INFO event=stage_start stage=application_update command=helper\\n"
                "Waiting for service response\\n"
                "2026 level=ERROR event=stage_end stage=application_update status=failed exit_code=5\\n",
                encoding="utf-8",
            )
            r = self.run_helper(f"forge_result_stage_error '{log}' application_update")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout, "")
            _, detail = self.parse(self.result(
                "lxc", "ERROR", "update_failed", "5", "application_update", "", "unavailable"
            ))
            self.assertEqual(detail,
                             "ERROR: application_update (exit 5); recovery unavailable (no artifact)")

    def test_bulk_publisher_never_prints_duplicate_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            handoff = Path(tmp) / "handoff"
            r = self.run_helper(
                f'FORGE_RESULTS_AGGREGATE=bulk FORGE_RESULT_DETAIL_FILE="{handoff}" '
                "forge_result_publish lxc 101 hostname true true ERROR update_failed "
                '17 - - - - os_update "" success ""',
            )
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout, "")
            fields = handoff.read_text(encoding="utf-8").rstrip("\n").split("\t")
            self.assertEqual(fields[1:], ["os_update", "success"])
            self.assertEqual(unquote(fields[0]), "ERROR: os_update (exit 17); recovery succeeded")

    def test_malformed_encoded_result_is_rejected(self):
        r = self.run_helper(
            "forge_result_print lxc 101 hostname true true OK completed "
            '"" - - - - "OK%0G" - -',
        )
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
