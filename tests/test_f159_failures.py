#!/usr/bin/env python3
"""F159: failed/blocked target details reuse F224/F225 result records."""

import os
import subprocess
import unittest
from pathlib import Path

from test_final_table import record


RENDERER = Path(__file__).resolve().parents[1] / "lib/results/table.py"
HEADING = "Failed and blocked targets ("


def row(vmid, status, *, name=None, detail=None, stage="os_update",
        exit_code="42", reason=None, recovery="-", type_="lxc"):
    kwargs = dict(
        vmid=vmid, type_=type_, name=name or ("test-host" if type_ == "host" else f"guest{vmid}"),
        status=status,
    )
    if status == "ERROR":
        kwargs.update(
            reason=reason or "update_failed", exit_code=exit_code,
            stage=stage, recovery=recovery,
            detail=detail if detail is not None else
            f"ERROR: {stage} (exit {exit_code})",
        )
    elif status == "NOT_RUN":
        kwargs.update(
            reason=reason or "preflight_blocked", attempted=False,
            apt="-", before="-", after="-", url="-",
            detail=detail if detail is not None else
            "NOT RUN: preflight blocked the update",
        )
    elif status == "SKIPPED":
        kwargs.update(
            reason=reason or "excluded", selected=False, attempted=False,
            apt="-", before="-", after="-", url="-",
            detail=detail if detail is not None else
            "SKIPPED: excluded by configuration",
        )
    else:
        kwargs["detail"] = detail if detail is not None else "OK"
    return record(**kwargs)


class FailedTargetSummaryTests(unittest.TestCase):
    def render(self, rows, *, width=110, color="never", **env):
        return subprocess.run(
            ["python3", str(RENDERER)],
            input="\n".join(rows) + "\n",
            capture_output=True, text=True, check=False,
            env={**os.environ, "FORGE_TABLE_WIDTH": str(width),
                 "FORGE_TABLE_COLOR": color, **env},
        )

    def failure_section(self, output):
        self.assertEqual(output.count(HEADING), 1, output)
        return output[output.index(HEADING):]

    def test_success_empty_skipped_and_warning_only_have_no_failure_summary(self):
        scenarios = [
            [],
            [row("100", "OK")],
            [row("100", "SKIPPED"), row("113", "SKIPPED", reason="stopped")],
            [row("100", "OK", detail="OK; WARNING: fstrim failed (exit 8)")],
            [row("HOST", "OK", type_="host"), row("113", "SKIPPED")],
        ]
        for rows in scenarios:
            with self.subTest(rows=rows):
                result = self.render(rows)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn(HEADING, result.stdout)
                self.assertEqual(result.stdout.count("Overall result: SUCCESS"), 1)

    def test_single_failed_lxc_shows_target_and_actual_stage_without_guessed_cause(self):
        result = self.render([
            row("110", "ERROR", name="whisparr",
                detail="ERROR: application_update (exit 42)",
                stage="application_update"),
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = self.failure_section(result.stdout)
        self.assertIn("Failed and blocked targets (1):", summary)
        self.assertIn("  110 | whisparr | ERROR", summary)
        self.assertIn("    Detail: ERROR: application_update (exit 42)", summary)
        self.assertNotIn("dependency", summary)
        self.assertNotIn("HTTP", summary)
        self.assertIn("Overall result: FAILED", result.stdout)

    def test_failures_and_blocked_are_distinct_and_ordered(self):
        result = self.render([
            row("HOST", "ERROR", type_="host", name="bv.deulo.com",
                detail="ERROR: os_update (exit 7): apt dependency error", exit_code="7"),
            row("100", "NOT_RUN", detail="NOT RUN: host update failed",
                reason="host_update_failed"),
            row("101", "SKIPPED"),
            row("111", "NOT_RUN", detail="NOT RUN: host update failed",
                reason="host_update_failed"),
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = self.failure_section(result.stdout)
        self.assertIn("Failed and blocked targets (3):", summary)
        self.assertIn("  HOST | bv.deulo.com | ERROR", summary)
        self.assertIn("  100 | guest100 | NOT_RUN", summary)
        self.assertIn("  111 | guest111 | NOT_RUN", summary)
        self.assertNotIn("101 |", summary)
        self.assertNotIn("excluded by configuration", summary)
        self.assertLess(summary.index("  HOST |"), summary.index("  100 |"))
        self.assertLess(summary.index("  100 |"), summary.index("  111 |"))
        self.assertIn("Detail: ERROR: os_update (exit 7): apt dependency error", summary)
        self.assertEqual(summary.count("NOT RUN: host update failed"), 2)

    def test_recovery_failure_does_not_hide_primary_failure(self):
        result = self.render([
            row("110", "ERROR", name="whisparr", stage="application_update",
                exit_code="42", recovery="failed:9",
                detail="ERROR: application_update (exit 42): HTTP 503; "
                       "recovery failed (exit 9)"),
            row("111", "OK", detail="OK; WARNING: reboot requirement unknown"),
        ])
        self.assertEqual(result.returncode, 0)
        summary = self.failure_section(result.stdout)
        self.assertIn("  110 | whisparr | ERROR", summary)
        self.assertIn("ERROR: application_update (exit 42): HTTP 503; "
                      "recovery failed (exit 9)", summary)
        self.assertNotIn("111 |", summary)
        self.assertIn("Overall result: PARTIAL", result.stdout)

    def test_multiple_errors_cannot_share_or_swap_diagnostics(self):
        result = self.render([
            row("100", "ERROR", exit_code="23", stage="os_update",
                detail="ERROR: os_update (exit 23): package lock"),
            row("110", "ERROR", exit_code="42", stage="application_update",
                detail="ERROR: application_update (exit 42): repository unavailable"),
        ])
        self.assertEqual(result.returncode, 0)
        summary = self.failure_section(result.stdout)
        self.assertIn("  100 | guest100 | ERROR\n    Detail: ERROR: os_update (exit 23): package lock",
                      summary)
        self.assertIn("  110 | guest110 | ERROR\n    Detail: ERROR: application_update (exit 42): repository unavailable",
                      summary)
        self.assertEqual(summary.count("  100 |"), 1)
        self.assertEqual(summary.count("  110 |"), 1)

    def test_blocked_preflight_uses_known_reason_without_fabricating_error(self):
        result = self.render([
            row("HOST", "NOT_RUN", type_="host",
                detail="NOT RUN: preflight blocked the update"),
            row("111", "NOT_RUN",
                detail="NOT RUN: LXC 111 root space preflight failed"),
            row("113", "SKIPPED"),
        ])
        self.assertEqual(result.returncode, 0)
        summary = self.failure_section(result.stdout)
        self.assertIn("Failed and blocked targets (2):", summary)
        self.assertIn("NOT RUN: LXC 111 root space preflight failed", summary)
        self.assertNotIn("  113 |", summary)
        self.assertIn("Overall result: FAILED", result.stdout)

    def test_multiline_hostile_diagnostics_remain_inert_in_both_sections(self):
        detail = "ERROR: command failed\nstatus=OK\t\033[31mFAKE\033[0m\x07"
        result = self.render([row("110", "ERROR", detail=detail)], width=75)
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = self.failure_section(result.stdout)
        self.assertNotIn("\x1b", result.stdout)
        self.assertNotIn("\x07", result.stdout)
        self.assertIn("    Detail: ERROR: command failed", summary)
        self.assertIn("      | status=OK", summary)
        self.assertIn("FAKE", summary)
        self.assertNotIn("\nstatus=OK", summary)

    def test_multiline_updater_diagnostics_and_recovery_are_separate(self):
        detail = (
            "ERROR: application_update (exit 42)\n"
            "Failed stage output:\n"
            "npm ERR! code ERESOLVE\n"
            "npm ERR! unable to resolve dependency tree\n"
            "npm ERR! Conflicting peer dependency\n"
            "recovery succeeded"
        )
        result = self.render([
            row("104", "ERROR", name="immich", stage="application_update",
                detail=detail, recovery="success"),
            row("111", "OK", detail="OK"),
        ], width=78)
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = self.failure_section(result.stdout)
        self.assertIn("  104 | immich | ERROR", summary)
        self.assertIn("    Detail: ERROR: application_update (exit 42)", summary)
        self.assertIn("      | Failed stage output:", summary)
        self.assertIn("      | npm ERR! code ERESOLVE", summary)
        self.assertIn("      | npm ERR! unable to resolve dependency tree", summary)
        self.assertIn("      | recovery succeeded", summary)
        self.assertNotIn("  111 |", summary)
        self.assertIn("Overall result: PARTIAL", result.stdout)
        self.assertEqual(summary.count("Failed and blocked targets"), 1)

    def test_long_errors_remain_readable_and_not_truncated(self):
        detail = "ERROR: os_update (exit 42): " + "cannot resolve dependency " * 15
        result = self.render([row("110", "ERROR", detail=detail)], width=70)
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = self.failure_section(result.stdout)
        self.assertGreater(summary.count("dependency"), 5)
        self.assertIn("  110 | guest110 | ERROR", summary)
        self.assertIn("\n            cannot", summary)
        self.assertEqual(summary.count("Failed and blocked targets ("), 1)

    def test_color_is_presentation_only(self):
        rows = [row("100", "ERROR"), row("111", "NOT_RUN")]
        plain = self.render(rows)
        forced = self.render(rows, color="always")
        no_color = self.render(rows, color="always", NO_COLOR="1")
        for result in (plain, forced, no_color):
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Failed and blocked targets (2):", result.stdout)
        self.assertNotIn("\033[", plain.stdout)
        self.assertIn("\033[31mERROR\033[0m", forced.stdout)
        self.assertIn("\033[33mNOT_RUN\033[0m", forced.stdout)
        self.assertNotIn("\033[", no_color.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
