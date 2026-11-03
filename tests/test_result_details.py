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
        self.assertEqual(len(row), 16 if row["status"] == "ERROR" else 15)
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

    def test_direct_host_software_record_is_escaped_and_readable(self):
        platform = "Proxmox VE 9.0.11; Debian 13; Kernel running 7.0.14-25-pve"
        r = self.run_helper(
            "forge_result_publish host HOST bv.deulos.com true true OK completed "
            "'' '-' '-' '-' '-' '-' '' '-' '' "
            "'Proxmox VE 9.0.11; Debian 13; Kernel running 7.0.14-25-pve'"
        )
        row, detail = self.parse(r)
        self.assertEqual(row["type"], "host")
        self.assertIn("%20", row["host_platform"])
        self.assertEqual(unquote(row["host_platform"]), platform)
        self.assertEqual(detail, "OK")
        table = subprocess.run(
            ["python3", str(ROOT / "lib/results/table.py")],
            input=r.stdout, capture_output=True, text=True, check=False,
        )
        self.assertEqual(table.returncode, 0, table.stderr)
        self.assertIn("Proxmox VE 9.0.11", table.stdout)
        self.assertIn("Debian 13", table.stdout)

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
                "2026 level=INFO event=stage_start stage=os_update command=apt\n"
                "ERROR: failure from unrelated earlier stage\n"
                "2026 level=ERROR event=stage_end stage=os_update status=failed exit_code=1\n"
                "2026 level=INFO event=stage_start stage=application_update command=helper\n"
                "Downloading app...\n"
                + "\n".join(diagnostics) + "\n"
                "This line does not explicitly report an error\n"
                "2026 level=ERROR event=stage_end stage=application_update status=failed exit_code=42\n"
                "2026 level=INFO event=stage_start stage=recovery_health command=check\n"
                "ERROR: rollback health failure must not leak\n"
                "2026 level=ERROR event=stage_end stage=recovery_health status=failed exit_code=8\n",
                encoding="utf-8",
            )
            extracted = self.run_helper(
                f"forge_result_stage_error '{log}' application_update"
            )
            self.assertEqual(extracted.returncode, 0, extracted.stderr)
            self.assertEqual(extracted.stdout.splitlines(), diagnostics)

            row, detail = self.parse(self.result(
                "lxc", "ERROR", "update_failed", "42", "application_update",
                extracted.stdout.rstrip("\n"), "success",
            ))
            self.assertEqual(row["exit_code"], "42")
            self.assertEqual(row["recovery"], "success")
            self.assertIn("Failed stage output:\n" + "\n".join(diagnostics), detail)
            self.assertTrue(detail.endswith("\nrecovery succeeded"), detail)
            self.assertNotIn("unrelated earlier stage", detail)
            self.assertNotIn("rollback health failure", detail)

    def test_under_provisioned_guests_report_required_and_current_resources(self):
        # The two real Community Scripts failure shapes must work for any VMID,
        # not just the WireGuard and Trek containers that exposed the problem.
        for vmid, required_cpu, required_ram, actual_cpu, actual_ram in (
            ("100", 1, 1024, 1, 512),
            ("115", 2, 4096, 2, 2048),
            ("213", 4, 8192, 2, 4096),
        ):
            with self.subTest(vmid=vmid), tempfile.TemporaryDirectory() as tmp:
                log = Path(tmp) / "stage.log"
                requirements = (
                    f"Required: {required_cpu} CPU, {required_ram}MB RAM | "
                    f"Current: {actual_cpu} CPU, {actual_ram}MB RAM"
                )
                log.write_text(
                    "2026 level=INFO event=stage_start stage=application_update command=helper\n"
                    "Building application...\n"
                    f"  💡 {requirements}\n"
                    "Please ensure that this LXC has sufficient resources for the build.\n"
                    "  Not continuing: LXC is under-provisioned and there is nobody to ask.\n"
                    f"ERROR: application updater failed for LXC {vmid} (exit code: 113)\n"
                    "2026 level=ERROR event=stage_end stage=application_update status=failed exit_code=113\n"
                    "2026 level=INFO event=stage_start stage=recovery_health command=check\n"
                    "ERROR: unrelated recovery failure\n"
                    "2026 level=ERROR event=stage_end stage=recovery_health status=failed exit_code=2\n",
                    encoding="utf-8",
                )
                extracted = self.run_helper(
                    f"forge_result_stage_error '{log}' application_update"
                )
                self.assertEqual(extracted.returncode, 0, extracted.stderr)
                self.assertIn(
                    "ERROR: Insufficient update CPU/RAM: " + requirements,
                    extracted.stdout,
                )
                self.assertIn("under-provisioned", extracted.stdout)
                self.assertNotIn("unrelated recovery failure", extracted.stdout)
                # Verify the existing encoded handoff also puts the diagnosis
                # in the user's actual final Result column and failures list.
                result = self.run_helper(
                    f'forge_result_publish lxc {vmid} guest true true ERROR '
                    f'update_failed 113 - - - - application_update '
                    f'"$(forge_result_stage_error \'{log}\' application_update)" '
                    f'success ""'
                )
                row, detail = self.parse(result)
                self.assertEqual(row["failed_stage"], "application_update")
                self.assertEqual(row["recovery"], "success")
                self.assertIn(requirements, detail)
                self.assertIn("recovery succeeded", detail)
                table = subprocess.run(
                    ["python3", str(ROOT / "lib/results/table.py")],
                    input=result.stdout, capture_output=True, text=True, check=False,
                )
                self.assertEqual(table.returncode, 0, table.stderr)
                self.assertIn("Insufficient update CPU/RAM", table.stdout)
                self.assertIn(f"{required_ram}MB", table.stdout)
                self.assertIn(f"{actual_ram}MB", table.stdout)

    def test_resource_diagnosis_requires_explicit_failure_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "stage.log"
            log.write_text(
                "2026 level=INFO event=stage_start stage=application_update command=helper\n"
                "Required: 2 CPU, 4096MB RAM | Current: 2 CPU, 2048MB RAM\n"
                "ERROR: request failed with HTTP 404\n"
                "2026 level=ERROR event=stage_end stage=application_update status=failed exit_code=113\n"
                "2026 level=INFO event=stage_start stage=recovery_health command=health\n"
                "Not continuing: LXC is under-provisioned\n"
                "2026 level=INFO event=stage_end stage=recovery_health status=success exit_code=0\n",
                encoding="utf-8",
            )
            r = self.run_helper(
                f"forge_result_stage_error '{log}' application_update"
            )
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.strip(), "ERROR: request failed with HTTP 404")

    def test_unprefixed_out_of_memory_is_reported_without_fabricated_limits(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "stage.log"
            log.write_text(
                "2026 level=INFO event=stage_start stage=custom_scripts command=script\n"
                "Build exited: out of memory\n"
                "2026 level=ERROR event=stage_end stage=custom_scripts status=failed exit_code=137\n",
                encoding="utf-8",
            )
            r = self.run_helper(f"forge_result_stage_error '{log}' custom_scripts")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("Updater reported insufficient CPU or memory", r.stdout)
            self.assertIn("Build exited: out of memory", r.stdout)
            self.assertNotIn("Required:", r.stdout)

    def test_verbose_failure_keeps_first_and_last_bounded_diagnostic_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "stage.log"
            diagnostic_lines = [f"npm ERR! original-error-{i}" for i in range(1, 17)]
            log.write_text(
                "2026 level=INFO event=stage_start stage=application_update command=helper\n"
                + "\n".join(diagnostic_lines) + "\n"
                "2026 level=ERROR event=stage_end stage=application_update status=failed exit_code=1\n",
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
                "2026 level=INFO event=stage_start stage=application_update command=helper\n"
                "Waiting for service response\n"
                "2026 level=ERROR event=stage_end stage=application_update status=failed exit_code=5\n",
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
            self.assertEqual(fields[1:], ["os_update", "success", "-"])
            self.assertEqual(unquote(fields[0]), "ERROR: os_update (exit 17); recovery succeeded")

    def test_malformed_encoded_result_is_rejected(self):
        r = self.run_helper(
            "forge_result_print lxc 101 hostname true true OK completed "
            '"" - - - - "OK%0G" - -',
        )
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
