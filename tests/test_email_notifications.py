#!/usr/bin/env python3
"""F153/F154: integration of optional Proxmox root mail with final results.

Real bulk coordinator + F225/F157/F159 records, fake host/LXC operations and
fake sendmail executable. These tests NEVER send actual email or run updates.
"""

import json
import os
import subprocess
import unittest
from pathlib import Path

from test_results import ResultAggregationTests


MAIL_STUB = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

with Path(os.environ["FORGE_TEST_MAIL_LOG"]).open("a", encoding="utf-8") as output:
    output.write(json.dumps({"args": sys.argv[1:], "email": sys.stdin.read()}) + "\n")
sys.exit(int(os.environ.get("FORGE_TEST_MAIL_EXIT", "0")))
"""


class BulkNotificationTests(unittest.TestCase):
    setUp = ResultAggregationTests.setUp
    invoke = ResultAggregationTests.invoke
    inventory = staticmethod(ResultAggregationTests.inventory)

    def prepare_mail(self):
        bin_dir = self.root / "bin"
        bin_dir.mkdir(exist_ok=True)
        mailer = bin_dir / "sendmail"
        mailer.write_text(MAIL_STUB, encoding="utf-8")
        mailer.chmod(0o755)
        self.mail_log = self.root / "mail.jsonl"
        self.env["PATH"] = f"{bin_dir}:{self.env['PATH']}"
        self.env["FORGE_TEST_MAIL_LOG"] = str(self.mail_log)

    def messages(self):
        if not self.mail_log.exists():
            return []
        return [json.loads(line) for line in self.mail_log.read_text().splitlines()]

    def test_defaults_disable_all_email_even_on_failure(self):
        self.prepare_mail()
        result, _ = self.invoke("all", FORGE_TEST_LXC_CODES='{"111":42}')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("result_global status=PARTIAL", result.stdout)
        self.assertEqual(self.messages(), [])

    def test_errors_only_sends_one_mixed_failure_email_with_own_cause(self):
        self.prepare_mail()
        result, calls = self.invoke(
            "all", FORGE_TEST_EMAIL_NOTIFICATIONS="true",
            FORGE_TEST_LXC_CODES='{"111":42}',
            FORGE_TEST_LXC_DETAIL=json.dumps({
                "111": ["ERROR%3A%20application_update%20%28exit%2042%29"
                        "%3A%20HTTP%20503%3B%20recovery%20succeeded",
                        "application_update", "success"],
            }),
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        messages = self.messages()
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]["args"], ["-t", "-oi"])
        email = messages[0]["email"]
        self.assertTrue(email.startswith("To: root\nSubject: [Proxmox Forge] PARTIAL - update results\n"))
        self.assertIn("Content-Type: text/plain; charset=UTF-8\n", email)
        self.assertIn("result_global status=PARTIAL", email)
        self.assertIn("Failed and blocked targets (1):", email)
        self.assertIn("  111 | guest111 | ERROR", email)
        self.assertIn("ERROR: application_update (exit 42): HTTP 503; recovery succeeded", email)
        self.assertNotIn("\x1b", email)
        self.assertEqual([x["args"][0] for x in calls if x["kind"] == "lxc"],
                         ["100", "111", "115"])
        self.assertEqual(result.stdout.count("Forge final results"), 1)
        self.assertNotIn("email notification failed", result.stderr)

    def test_errors_only_skips_success_empty_disabled_and_only_warnings(self):
        self.prepare_mail()
        scenarios = [
            ("all", {}),
            ("lxc", {"FORGE_TEST_VMIDS": ""}),
            ("all", {"FORGE_TEST_RUNNING_LXC": "false",
                     "FORGE_TEST_UPDATE_HOST": "false"}),
            ("lxc", {"FORGE_TEST_EXCLUDE": "100,111,115"}),
        ]
        for mode, opts in scenarios:
            with self.subTest(mode=mode, opts=opts):
                result, _ = self.invoke(
                    mode, FORGE_TEST_EMAIL_NOTIFICATIONS="true", **opts,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.messages(), [])

    def test_all_outcomes_policy_false_sends_success_including_empty(self):
        self.prepare_mail()
        for mode, opts in [
            ("all", {}),
            ("lxc", {"FORGE_TEST_VMIDS": ""}),
        ]:
            with self.subTest(mode=mode, opts=opts):
                result, _ = self.invoke(
                    mode, FORGE_TEST_EMAIL_NOTIFICATIONS="true",
                    FORGE_TEST_NOTIFY_ONLY_ERRORS="false", **opts,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
        messages = self.messages()
        self.assertEqual(len(messages), 2)
        self.assertTrue(all("Subject: [Proxmox Forge] SUCCESS" in m["email"]
                            for m in messages))
        self.assertIn("Overall result: SUCCESS (no targets selected)",
                      messages[1]["email"])

    def test_preflight_blocked_is_reported_once_without_mutation(self):
        self.prepare_mail()
        result, calls = self.invoke(
            "all", FORGE_TEST_EMAIL_NOTIFICATIONS="true",
            FORGE_TEST_LOW_SPACE_VMID="111",
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(self.messages()), 1)
        email = self.messages()[0]["email"]
        self.assertIn("Subject: [Proxmox Forge] FAILED", email)
        self.assertIn("Failed and blocked targets (4):", email)
        self.assertIn("NOT RUN: LXC 111 root space preflight failed", email)
        self.assertNotIn("host", [c["kind"] for c in calls])
        self.assertNotIn("lxc", [c["kind"] for c in calls])

    def test_host_failure_keeps_exit_42_and_sends_one_partial_summary(self):
        self.prepare_mail()
        result, calls = self.invoke(
            "all", FORGE_TEST_EMAIL_NOTIFICATIONS="true",
            FORGE_TEST_HOST_CODE="42",
            FORGE_TEST_HOST_DETAIL='["ERROR%3A%20os_update%20%28exit%2042%29","os_update","-"]',
        )
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(len(self.messages()), 1)
        email = self.messages()[0]["email"]
        self.assertIn("Subject: [Proxmox Forge] PARTIAL", email)
        self.assertIn("ERROR: os_update (exit 42)", email)
        self.assertIn("Overall result: PARTIAL", email)
        self.assertNotIn("NOT RUN: host update failed", email)
        self.assertEqual([c["args"][0] for c in calls if c["kind"] == "lxc"],
                         ["100", "111", "115"])

    def test_sendmail_failure_is_warning_and_never_masks_original_exit(self):
        self.prepare_mail()
        for code, opts in [
            (0, {}),
            (42, {"FORGE_TEST_HOST_CODE": "42"}),
        ]:
            with self.subTest(code=code):
                result, _ = self.invoke(
                    "all", FORGE_TEST_EMAIL_NOTIFICATIONS="true",
                    FORGE_TEST_NOTIFY_ONLY_ERRORS="false",
                    FORGE_TEST_MAIL_EXIT="75", **opts,
                )
                self.assertEqual(result.returncode, code)
                self.assertIn("Forge email notification was not accepted", result.stderr)
                self.assertIn("Forge final results", result.stdout)
        self.assertEqual(len(self.messages()), 2)

    def test_notification_content_ignores_external_input_control_sequences(self):
        self.prepare_mail()
        hostile = "ERROR: application_update (exit 17)\nX-Injected: fake\t\033[31mBAD\033[0m"
        from urllib.parse import quote
        result, _ = self.invoke(
            "lxc", FORGE_TEST_EMAIL_NOTIFICATIONS="true",
            FORGE_TEST_LXC_CODES='{"111":17}',
            FORGE_TEST_LXC_DETAIL=json.dumps({
                "111": [quote(hostile, safe=""), "application_update", "-"],
            }),
        )
        self.assertEqual(result.returncode, 1)
        email = self.messages()[0]["email"]
        self.assertNotIn("\x1b", email)
        self.assertIn(" ⏎ ", email)
        self.assertIn("X-Injected: fake", email)
        self.assertNotIn("\nX-Injected:", email)

    def test_sender_is_missing_does_not_change_final_result(self):
        # Set an exclusive fake PATH for sendmail lookup, but retain Python and
        # bash for the coordinator by using a non-executable sendmail stub.
        self.prepare_mail()
        (self.root / "bin/sendmail").write_text("#!/bin/sh\nexit 69\n")
        result, _ = self.invoke(
            "all", FORGE_TEST_EMAIL_NOTIFICATIONS="true",
            FORGE_TEST_HOST_CODE="33",
        )
        self.assertEqual(result.returncode, 33)
        self.assertIn("Forge email notification was not accepted", result.stderr)
        self.assertIn("result_global status=FAILED", result.stdout)
        self.assertEqual(self.messages(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
