#!/usr/bin/env python3
"""F225/F157/F159: render one authoritative final-results snapshot without updates."""

import os
import re
import shutil
import sys
import textwrap
import unicodedata
from collections import Counter
from urllib.parse import unquote

FIELDS = (
    "type", "vmid", "name", "selected", "attempted", "status", "reason",
    "apt_upgraded", "app_before", "app_after", "app_repository",
    "failed_stage", "recovery", "result_detail",
)
STATUSES = ("OK", "ERROR", "SKIPPED", "NOT_RUN")
HEADERS = ("VMID", "Name", "APT", "Application version", "Changelog", "Result")
COLORS = {"OK": "\033[32m", "ERROR": "\033[31m",
          "SKIPPED": "\033[33m", "NOT_RUN": "\033[33m"}


def clean(value):
    """No log field may inject an ANSI sequence, newline or terminal control."""
    value = str(value).replace("\r\n", "\n").replace("\r", "\n")
    return "".join(
        " ⏎ " if ch == "\n" else
        " " if unicodedata.category(ch)[0] == "C" else ch
        for ch in value
    ).strip()


def parse(line):
    if not line.startswith("result_target "):
        raise ValueError("not a result_target record")
    record = {}
    for entry in line.rstrip("\n").split()[1:]:
        if "=" not in entry:
            raise ValueError("invalid result_target token")
        key, value = entry.split("=", 1)
        if key in record:
            raise ValueError("duplicate result_target field")
        record[key] = value
    if any(key not in record for key in FIELDS):
        raise ValueError("incomplete result_target record")
    if record["status"] not in STATUSES:
        raise ValueError("unknown result status")
    if record["type"] not in ("host", "lxc"):
        raise ValueError("invalid result target type")
    if record["selected"] not in ("true", "false") or record["attempted"] not in ("true", "false"):
        raise ValueError("invalid selection state")
    if record["type"] == "host":
        if record["vmid"] != "HOST":
            raise ValueError("invalid host identifier")
    elif not re.fullmatch(r"[0-9]+", record["vmid"]):
        raise ValueError("invalid LXC identifier")
    if not re.fullmatch(r"([A-Za-z0-9_.~-]|%[0-9A-F]{2})+", record["result_detail"]):
        raise ValueError("invalid encoded result")
    if "exit_code" in record and not re.fullmatch(r"[0-9]+", record["exit_code"]):
        raise ValueError("invalid exit code")
    return record


def fields(row):
    before, after = row["app_before"], row["app_after"]
    if before == "-" or after == "-":
        app = "—"
    elif before == after:
        app = before
    else:
        app = f"{before} → {after}"
    detail = clean(unquote(row["result_detail"], encoding="utf-8", errors="replace"))
    return (
        row["vmid"], clean(row["name"]),
        "—" if row["apt_upgraded"] == "-" else row["apt_upgraded"],
        clean(app),
        "—" if row["app_repository"] == "-" else clean(row["app_repository"]),
        detail,
    )


def color_enabled():
    if "NO_COLOR" in os.environ:
        return False
    requested = os.environ.get("FORGE_TABLE_COLOR", "auto")
    if requested == "never":
        return False
    return requested == "always" or (requested == "auto" and sys.stdout.isatty())


def display_width():
    override = os.environ.get("FORGE_TABLE_WIDTH", "")
    if override.isdigit():
        return max(60, min(400, int(override)))
    return shutil.get_terminal_size((120, 24)).columns


def colored(message, status, enabled):
    if not enabled:
        return message
    return COLORS[status] + message + "\033[0m"


def wrap(value, size):
    # Do not break URLs, version identifiers or hyphenated diagnostics.
    return textwrap.wrap(
        value, width=size, break_long_words=False, break_on_hyphens=False,
        replace_whitespace=True, drop_whitespace=True,
    ) or [""]


def summarize(rows):
    """Compute F157 once from exactly the F225 source records.

    Excluded/skipped targets are intentional; eligible NOT_RUN targets are
    blockers, never successes. With no selected targets the run succeeded
    without attempting any updates, rather than claiming an update occurred.
    """
    counts = Counter(row["status"] for row in rows)
    selected = sum(row["selected"] == "true" for row in rows)
    attempted = sum(row["attempted"] == "true" for row in rows)
    incomplete = counts["ERROR"] + counts["NOT_RUN"]
    if incomplete:
        status = "PARTIAL" if counts["OK"] else "FAILED"
    else:
        status = "SUCCESS"
    return counts, selected, attempted, status



def emit_failures(rows, width, enabled):
    """F159: show only real errors and blocked targets from F225's rows.

    The existing escaped result_detail is the sole diagnostic source. In
    particular, recovery cannot overwrite the original failure, and skipped
    guests and nonfatal warnings must not appear in this list.
    """
    affected = [row for row in rows if row["status"] in ("ERROR", "NOT_RUN")]
    if not affected:
        return
    print(f"\nFailed and blocked targets ({len(affected)}):")
    prefix = "    Detail: "
    for row in affected:
        name = clean(row["name"])
        status = row["status"]
        print(f'  {row["vmid"]} | {name} | {colored(status, status, enabled)}')
        # Share precisely the decoded/sanitized detail used by the Result
        # column. Wrap diagnostics on narrow terminals without truncation.
        detail = fields(row)[5]
        for index, part in enumerate(wrap(detail, max(32, width - len(prefix)))):
            print((prefix if index == 0 else " " * len(prefix)) + part)


def emit(rows, width, enabled):
    print("\nForge final results")
    values = [fields(row) for row in rows]
    # Full 6-column grid only where URL and diagnostics remain readable.
    full = width >= 166
    if full:
        caps = (6, 24, 5, 29, 58, min(70, max(32, width - 130)))
        sizes = [
            min(cap, max(len(HEADERS[i]), *(len(v[i]) for v in values)))
            for i, cap in enumerate(caps)
        ]
        def output(cells):
            print(" | ".join(cell.ljust(sizes[i]) for i, cell in enumerate(cells)).rstrip())
        output(HEADERS)
        print("-+-".join("-" * size for size in sizes))
        for row, cells in zip(rows, values):
            parts = [wrap(value, sizes[i]) for i, value in enumerate(cells)]
            for idx in range(max(map(len, parts))):
                physical = [col[idx] if idx < len(col) else "" for col in parts]
                if idx < len(parts[5]):
                    physical[5] = colored(physical[5], row["status"], enabled)
                output(physical)
    else:
        # Small terminals: never cut a real GitHub link in half or hide errors.
        # One logical row per target, with two indented continuation fields.
        print(" | ".join(HEADERS))
        print("-" * min(width, 75))
        for row, cells in zip(rows, values):
            print(" | ".join(cells[:4]))
            print("    Changelog: " + cells[4])
            prefix = "    Result: "
            detail = wrap(cells[5], max(32, width - len(prefix)))
            for idx, part in enumerate(detail):
                print((prefix if idx == 0 else " " * len(prefix)) +
                      colored(part, row["status"], enabled))
    counts, selected, attempted, status = summarize(rows)
    print(
        "Totals: targets={total} selected={selected} attempted={attempted} "
        "OK={ok} ERROR={error} SKIPPED={skipped} NOT_RUN={not_run}".format(
            total=len(rows), selected=selected, attempted=attempted,
            ok=counts["OK"], error=counts["ERROR"], skipped=counts["SKIPPED"],
            not_run=counts["NOT_RUN"],
        )
    )
    # The machine-readable F157 outcome uses precisely the same snapshot as
    # the human table and totals. This is not a notification or second collector.
    print(
        "result_global status={status} targets={total} selected={selected} "
        "attempted={attempted} succeeded={ok} failed={error} "
        "skipped={skipped} not_run={not_run}".format(
            status=status, total=len(rows), selected=selected, attempted=attempted,
            ok=counts["OK"], error=counts["ERROR"], skipped=counts["SKIPPED"],
            not_run=counts["NOT_RUN"],
        )
    )
    note = " (no targets selected)" if selected == 0 else ""
    print(f"Overall result: {status}{note}")
    emit_failures(rows, width, enabled)


def main():
    records = [line for line in sys.stdin if line.startswith("result_target ")]
    rows = [parse(line) for line in records]
    emit(rows, display_width(), color_enabled())


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as exc:
        print("ERROR: cannot render final results: " + str(exc), file=sys.stderr)
        sys.exit(2)
