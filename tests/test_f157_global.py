#!/usr/bin/env python3
"""F157: global outcome is derived exclusively from F225's result_target rows."""

import os
import subprocess
import unittest
from pathlib import Path

from test_final_table import record


RENDERER = Path(__file__).resolve().parents[1] / "lib/results/table.py"


def target(vmid, status, *, type_="lxc", detail=None):
    detail = detail or status
    if status == "OK":
        return record(vmid=vmid, type_=type_, name="host" if type_ == "host" else f"guest{vmid}",
                      status=status, detail=detail)
    if status == "ERROR":
        return record(vmid=vmid, type_=type_, name="host" if type_ == "host" else f"guest{vmid}",
                      status=status, reason="update_failed", exit_code=42,
                      stage="application_update", detail="ERROR: application_update (exit 42)")
    if status == "SKIPPED":
        return record(vmid=vmid, type_=type_, name="host" if type_ == "host" else f"guest{vmid}",
                      status=status, reason="excluded", selected=False,
                      attempted=False, apt="-", before="-", after="-", url="-",
                      detail="SKIPPED: excluded by configuration")
    if status == "NOT_RUN":
        return record(vmid=vmid, type_=type_, name="host" if type_ == "host" else f"guest{vmid}",
                      status=status, reason="preflight_blocked", selected=True,
                      attempted=False, apt="-", before="-", after="-", url="-",
                      detail="NOT RUN: preflight blocked the update")
    raise ValueError(status)


class F157GlobalOutcomeTests(unittest.TestCase):
    def render(self, targets, width=98):
        return subprocess.run(
            ["python3", str(RENDERER)], input="\n".join(targets) + "\n",
            capture_output=True, text=True,
            env={**os.environ, "FORGE_TABLE_WIDTH": str(width),
                 "FORGE_TABLE_COLOR": "never"},
            check=False,
        )

    def test_full_status_truth_table_and_authoritative_counts(self):
        cases = [
            ("empty inventory", [], "SUCCESS", (0, 0, 0, 0, 0, 0)),
            ("all explicitly skipped", ["SKIPPED", "SKIPPED"], "SUCCESS",
             (2, 0, 0, 0, 2, 0)),
            ("one OK", ["OK"], "SUCCESS", (1, 1, 0, 0, 0, 0)),
            ("some skipped OK", ["SKIPPED", "OK", "SKIPPED"], "SUCCESS",
             (3, 1, 0, 0, 2, 0)),
            ("one failed", ["ERROR"], "FAILED", (1, 0, 1, 0, 0, 0)),
            ("all failed", ["ERROR", "ERROR"], "FAILED", (2, 0, 2, 0, 0, 0)),
            ("all blocked", ["NOT_RUN", "NOT_RUN"], "FAILED",
             (2, 0, 0, 2, 0, 0)),
            ("failure and blocked", ["ERROR", "NOT_RUN", "SKIPPED"], "FAILED",
             (3, 0, 1, 1, 1, 0)),
            ("partial with error", ["OK", "ERROR"], "PARTIAL",
             (2, 1, 1, 0, 0, 0)),
            ("partial with not run", ["OK", "NOT_RUN", "SKIPPED"], "PARTIAL",
             (3, 1, 0, 1, 1, 0)),
            ("host succeeded all guests failed", ["OK", "ERROR", "ERROR"], "PARTIAL",
             (3, 1, 2, 0, 0, 0)),
            ("warning only cannot become partial",
             ["OK", "OK"], "SUCCESS", (2, 2, 0, 0, 0, 0)),
            ("failed recovery remains failed",
             ["ERROR", "SKIPPED"], "FAILED", (2, 0, 1, 0, 1, 0)),
        ]
        for name, states, expected, (total, ok, error, not_run, skipped, _) in cases:
            with self.subTest(case=name):
                rows = [target(str(i + 100), state) for i, state in enumerate(states)]
                result = self.render(rows)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.count("Forge final results"), 1)
                global_rows = [line for line in result.stdout.splitlines()
                               if line.startswith("result_global ")]
                self.assertEqual(len(global_rows), 1, result.stdout)
                selected = total - skipped
                attempted = ok + error
                expected_line = (
                    f"result_global status={expected} targets={total} selected={selected} "
                    f"attempted={attempted} succeeded={ok} failed={error} "
                    f"skipped={skipped} not_run={not_run}"
                )
                self.assertEqual(global_rows, [expected_line])
                self.assertIn(f"Overall result: {expected}", result.stdout)
                self.assertIn(
                    f"Totals: targets={total} selected={selected} attempted={attempted} "
                    f"OK={ok} ERROR={error} SKIPPED={skipped} NOT_RUN={not_run}",
                    result.stdout,
                )
                if selected == 0:
                    self.assertIn("SUCCESS (no targets selected)", result.stdout)
                else:
                    self.assertNotIn("no targets selected", result.stdout)

    def test_host_failure_and_unattempted_guests_is_failed_not_partial(self):
        result = self.render([
            target("HOST", "ERROR", type_="host"),
            target("100", "NOT_RUN"),
            target("111", "NOT_RUN"),
            target("113", "SKIPPED"),
        ])
        self.assertEqual(result.returncode, 0)
        self.assertIn(
            "result_global status=FAILED targets=4 selected=3 attempted=1 "
            "succeeded=0 failed=1 skipped=1 not_run=2",
            result.stdout,
        )

    def test_aggregate_unchanged_by_terminal_layout(self):
        rows = [target("100", "OK"), target("111", "ERROR"),
                target("113", "SKIPPED"), target("115", "NOT_RUN")]
        for width in (60, 110, 175, 240):
            with self.subTest(width=width):
                result = self.render(rows, width=width)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.count("result_global "), 1)
                self.assertIn(
                    "result_global status=PARTIAL targets=4 selected=3 "
                    "attempted=2 succeeded=1 failed=1 skipped=1 not_run=1",
                    result.stdout,
                )

    def test_non_results_log_lines_cannot_change_global_status(self):
        result = self.render([
            "update_all=success mode=all", "update_all=failed stage=lxc",
            "Overall result: SUCCESS",
            target("100", "ERROR"),
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("result_global status=FAILED", result.stdout)
        self.assertNotIn("result_global status=SUCCESS", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
