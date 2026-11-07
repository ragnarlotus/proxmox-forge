#!/usr/bin/env python3
"""F225/F157/F159: render one authoritative final-results snapshot without updates."""

import os
from contextlib import redirect_stdout
import re
import shutil
import sys
import textwrap
import unicodedata
from collections import Counter
from urllib.parse import unquote
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "i18n"))
from translate import tr  # noqa: E402

FIELDS = (
    "type", "vmid", "name", "selected", "attempted", "status", "reason",
    "apt_upgraded", "app_before", "app_after", "app_repository",
    "failed_stage", "recovery", "result_detail",
)
STATUSES = ("OK", "ERROR", "SKIPPED", "NOT_RUN")
def headers():
    return tuple(tr("table.header." + key) for key in (
        "vmid", "name", "apt", "version", "changelog", "result"
    ))
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
    if "host_platform" in record and not re.fullmatch(
            r"([A-Za-z0-9_.~-]|%[0-9A-F]{2})+", record["host_platform"]):
        raise ValueError("invalid encoded host platform")
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
    if row["type"] == "host" and row.get("host_platform", "-") != "-":
        app = clean(unquote(row["host_platform"], encoding="utf-8", errors="replace"))
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
    print("\n" + tr("table.failed", count=len(affected)))
    prefix = tr("table.detail")
    for row in affected:
        name = clean(row["name"])
        status = row["status"]
        print(f'  {row["vmid"]} | {name} | {colored(status, status, enabled)}')
        # F224 keeps original failed-stage messages separated by encoded
        # newlines. Prefix *every* decoded line so untrusted log content cannot
        # impersonate a result row or status header. The same record powers
        # the F225 table, F159 digest, notifications and retained history.
        detail = unquote(row["result_detail"], encoding="utf-8", errors="replace")
        logical_lines = detail.replace("\r\n", "\n").replace("\r", "\n").split("\n")
        for index, line in enumerate(logical_lines):
            line_prefix = prefix if index == 0 else "      | "
            for part_index, part in enumerate(wrap(clean(line), max(32, width - len(line_prefix)))):
                print((line_prefix if part_index == 0 else " " * len(line_prefix)) + part)



def compact_widths(values, width):
    """Fit six aligned columns inside a conventional 60-165-column terminal."""
    minimums = [4, 4, 3, 19, 9, 6]  # Header sizes; total including separators = 60.
    maximums = [6, 20, 5, 29, 9, 44]
    desired = [
        min(maximums[i], max([minimums[i], *(len(c[i]) for c in values)]))
        for i in range(6)
    ]
    sizes = minimums[:]
    remaining = max(0, width - sum(sizes) - 3 * (len(sizes) - 1))
    # Names, installed versions and failure diagnoses receive the most room.
    # Changelog is always a short footnote reference in this compact layout.
    while remaining and sizes != desired:
        for i in (1, 3, 5, 1, 3, 5, 0, 2):
            if remaining == 0:
                break
            if sizes[i] < desired[i]:
                sizes[i] += 1
                remaining -= 1
    return sizes


def emit_compact_table(rows, values, width, enabled):
    """Keep a genuine six-column grid and full clickable source URLs."""
    urls = list(dict.fromkeys(c[4] for c in values if c[4] != "—"))
    references = {url: f"[{i}]" for i, url in enumerate(urls, 1)}
    cells_by_row = [
        (c[0], c[1], c[2], c[3], references.get(c[4], "—"), c[5])
        for c in values
    ]
    sizes = compact_widths(cells_by_row, width)

    def output(cells):
        print(" | ".join(str(value).ljust(sizes[i])
                         for i, value in enumerate(cells)).rstrip())

    # Localized headers may be longer than the minimum compact column widths.
    header_columns = [
        textwrap.wrap(label, width=sizes[i], break_long_words=True,
                      break_on_hyphens=False) or [""]
        for i, label in enumerate(headers())
    ]
    for index in range(max(map(len, header_columns))):
        output([column[index] if index < len(column) else ""
                for column in header_columns])
    print("-+-".join("-" * size for size in sizes))
    for row, cells in zip(rows, cells_by_row):
        # All cell content is preserved, even on narrow terminals; URLs are
        # referenced instead of split into non-clickable pieces.
        columns = [
            textwrap.wrap(value, width=sizes[i], break_long_words=True,
                          break_on_hyphens=False, replace_whitespace=True,
                          drop_whitespace=True) or [""]
            for i, value in enumerate(cells)
        ]
        for idx in range(max(map(len, columns))):
            physical = [col[idx] if idx < len(col) else "" for col in columns]
            if idx < len(columns[5]):
                physical[5] = colored(physical[5], row["status"], enabled)
            output(physical)
    if urls:
        print("\n" + tr("table.changelog_links"))
        for url in urls:
            print(f"  {references[url]} {tr('table.changelog')}: {url}")


def emit(rows, width, enabled):
    print("\n" + tr("table.title"))
    values = [fields(row) for row in rows]
    # Full 6-column grid only where URL and diagnostics remain readable.
    full = width >= 166
    if full:
        caps = (6, 24, 5, 29, 58, min(70, max(32, width - 130)))
        sizes = [
            min(cap, max(len(headers()[i]), *(len(v[i]) for v in values)))
            for i, cap in enumerate(caps)
        ]
        def output(cells):
            print(" | ".join(cell.ljust(sizes[i]) for i, cell in enumerate(cells)).rstrip())
        output(headers())
        print("-+-".join("-" * size for size in sizes))
        for row, cells in zip(rows, values):
            parts = [wrap(value, sizes[i]) for i, value in enumerate(cells)]
            for idx in range(max(map(len, parts))):
                physical = [col[idx] if idx < len(col) else "" for col in parts]
                if idx < len(parts[5]):
                    physical[5] = colored(physical[5], row["status"], enabled)
                output(physical)
    else:
        emit_compact_table(rows, values, width, enabled)
    counts, selected, attempted, status = summarize(rows)
    print(
        tr("table.total") + " targets={total} selected={selected} attempted={attempted} "
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
    note = tr("table.no_targets") if selected == 0 else ""
    print(tr("table.overall", status=status, note=note))
    emit_failures(rows, width, enabled)


def main():
    records = [line for line in sys.stdin if line.startswith("result_target ")]
    rows = [parse(line) for line in records]
    width = display_width()
    enabled = color_enabled()
    # F141: persist the same presentation as plain text, while preserving the
    # original terminal output/TTY detection and its single visible table.
    run_log = os.environ.get("FORGE_RUN_LOG")
    if run_log:
        try:
            with open(run_log, "a", encoding="utf-8") as logfile:
                # Archived run logs keep canonical English presentation,
                # regardless of the active interactive language.
                previous_language = os.environ.get("FORGE_LANGUAGE")
                try:
                    os.environ["FORGE_LANGUAGE"] = "en"
                    with redirect_stdout(logfile):
                        emit(rows, width, False)
                finally:
                    if previous_language is None:
                        os.environ.pop("FORGE_LANGUAGE", None)
                    else:
                        os.environ["FORGE_LANGUAGE"] = previous_language
        except OSError as exc:
            print(f"WARNING: could not write Forge run summary: {exc}", file=sys.stderr)
    emit(rows, width, enabled)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as exc:
        print("ERROR: cannot render final results: " + str(exc), file=sys.stderr)
        sys.exit(2)
