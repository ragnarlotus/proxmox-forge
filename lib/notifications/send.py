#!/usr/bin/env python3
"""F153/F154/F237: email the final-result snapshot through Proxmox root mail.

Only invoked after F225 renders authoritative records. No separate collector,
outcome rules, notification template, recipient list or SMTP configuration.
"""

import io
import os
import subprocess
import sys
from contextlib import redirect_stdout
from pathlib import Path

# Share F225's exact parser, status classification, row diagnostics, F159
# digest and plain-text presentation. No independent result computation.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "results"))
import table  # noqa: E402


def notify(lines, mode, policy):
    if mode not in ("manual", "scheduled") or policy not in ("none", "errors", "all"):
        raise ValueError("invalid execution mode or notification policy")
    if policy == "none":
        return 0

    rows = [table.parse(line) for line in lines if line.startswith("result_target ")]
    _, _, _, status = table.summarize(rows)

    # An empty/no-change successful run is not an error.
    if policy == "errors" and status == "SUCCESS":
        return 0

    output = io.StringIO()
    with redirect_stdout(output):
        table.emit(rows, 110, False)

    # Fixed headers eliminate newline/header injection from guest data.
    message = (
        "To: root\n"
        f"Subject: {table.tr('email.subject', mode=mode.upper(), status=status)}\n"
        "MIME-Version: 1.0\n"
        "Content-Type: text/plain; charset=UTF-8\n"
        "Content-Transfer-Encoding: 8bit\n"
        "\n"
        + output.getvalue()
    )

    # Proxmox processes mail to local root as a system-mail notification,
    # respecting its existing matcher/target and root@pam recipient.
    # -oi prevents a line containing only '.' from ending a message.
    result = subprocess.run(
        ["sendmail", "-t", "-oi"], input=message, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30,
        check=False,
    )
    if result.returncode != 0:
        raise OSError(f"sendmail exited with status {result.returncode}")
    return 0


def main():
    if len(sys.argv) != 3:
        raise ValueError("usage: send.py manual|scheduled none|errors|all")
    return notify(sys.stdin, sys.argv[1], sys.argv[2])


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        print("ERROR: Forge email notification failed: " + str(exc), file=sys.stderr)
        sys.exit(1)
