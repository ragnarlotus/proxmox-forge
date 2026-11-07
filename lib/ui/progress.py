#!/usr/bin/env python3
"""Compact, terminal-only presentation of Forge update output.

The update workflow still owns execution, exit codes, backups and full target/run
logs. This process only consumes its stdout/stderr and never writes to those logs.
"""

import os
import re
import select
import shutil
import sys
import time
from urllib.parse import unquote

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(__file__)), "i18n"))
from translate import tr  # noqa: E402

# Every LXC uses this fixed set of milestones. An omitted stage counts as
# completed; recovery-only activities are additional, not planned milestones.
LXC_PROGRESS_STAGES = frozenset((
    "lifecycle_start", "requirements", "backup", "snapshot",
    "resource_apply", "os_update", "held_packages", "application_update",
    "custom_scripts", "resource_restore", "health", "fstrim",
    "reboot_check", "lifecycle_stop",
))
STAGES = LXC_PROGRESS_STAGES | frozenset((
    "recovery", "lifecycle_readiness", "startup", "shutdown",
))

CONTROL = re.compile(r"\x1b(?:\][^\x07]*(?:\x07|\x1b\\\\)|\[[0-?]*[ -/]*[@-~]|[@-_])")
RESULT = re.compile(r"^result_target ")
LXC_ID = re.compile(r"^type=lxc vmid=([0-9]+) name=([A-Za-z0-9_.-]+) ")


def fields(line):
    result = {}
    for token in line.split():
        if "=" in token:
            key, value = token.split("=", 1)
            result[key] = value
    return result


def safe_text(value, limit=240):
    value = CONTROL.sub("", value)
    value = "".join(c if c.isprintable() else " " for c in value)
    value = " ".join(value.split())
    return value[:limit]


def table_text(value):
    """Preserve table column spacing while stripping terminal controls."""
    value = CONTROL.sub("", value)
    return "".join(c if c.isprintable() else " " for c in value)


def duration_text(seconds):
    seconds = max(0, int(seconds))
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours} h {minutes} m {seconds} s"
    if minutes:
        return f"{minutes} m {seconds} s"
    return f"{seconds} s"


class Progress:
    def __init__(self, mode, target):
        self.tty = sys.stdout.isatty()
        self.color = self.tty and "NO_COLOR" not in os.environ
        self.mode = mode
        self.target = target
        self.total = 1 if mode != "bulk" else None
        self.started = {}
        self.completed = {}
        self.stage_done = {}
        self.names = {"HOST": tr("progress.host")}
        self.current = None
        self.stage = tr("progress.preflight")
        self.notices = []
        self.global_status = None
        # Preserve the workflow's own F225 table and failure digest verbatim
        # (apart from terminal controls); display them after the live dashboard.
        self.final_table_lines = None
        self.rendered_lines = 0
        self.last_output = 0
        self.last_snapshot = None
        self.run_id = os.environ.get("FORGE_RUN_ID", "")
        if mode == "host":
            self.begin("HOST")
        elif mode == "lxc":
            self.names[target] = safe_text(target, 40)
        self.render(force=True)

    def name(self, key):
        if key == "HOST":
            return self.names[key]
        name = self.names.get(key)
        return f"{key} · {name}" if name else f"LXC {key}"

    def begin(self, key):
        if key in self.completed:
            return
        self.started.setdefault(key, time.monotonic())
        self.current = key
        self.stage = tr("progress.requirements")

    def finish(self, key, status, exit_code=None):
        if key in self.completed:
            previous = self.completed[key]
            if previous[0] != status:
                self.completed[key] = (status, previous[1], exit_code)
            return
        elapsed = time.monotonic() - self.started.get(key, time.monotonic())
        self.completed[key] = (status, round(elapsed), exit_code)
        if self.current == key:
            self.current = None
            self.stage = tr("progress.next")

    def parse(self, raw):
        raw_line = raw.decode("utf-8", "replace")
        line = safe_text(raw_line, 2000)
        if self.final_table_lines is not None:
            # Consume the machine-readable result for dashboard status, but
            # keep it out of the human-facing final table.
            if not line.startswith("result_global "):
                self.final_table_lines.append(table_text(raw_line))
        elif line == tr("table.title"):
            self.final_table_lines = [table_text(raw_line)]
        if not line:
            return
        changed = False

        if line.startswith("update_all=start "):
            info = fields(line)
            if info.get("lxc_targets", "").isdigit():
                self.total = int(info["lxc_targets"]) + (info.get("update_host") == "true")
            self.stage = tr("progress.starting")
            changed = True
        elif line == "update_all_stage=start stage=host":
            self.begin("HOST")
            changed = True
        elif line.startswith("update_all_target=start "):
            key = fields(line).get("vmid")
            if key and key.isdigit():
                self.begin(key)
                changed = True
        elif line.startswith("update_all_stage=") and "stage=host" in line:
            if line.startswith("update_all_stage=success "):
                self.finish("HOST", "OK")
                changed = True
            elif line.startswith("update_all_stage=failed "):
                self.finish("HOST", "ERROR", fields(line).get("exit_code"))
                changed = True
        elif line.startswith("update_all_target="):
            key = fields(line).get("vmid")
            if key and key.isdigit():
                if line.startswith("update_all_target=success "):
                    self.finish(key, "OK")
                    changed = True
                elif line.startswith("update_all_target=failed "):
                    self.finish(key, "ERROR", fields(line).get("exit_code"))
                    changed = True
        elif line.startswith("stage=start name="):
            stage = fields(line).get("name", "")
            self.stage = (tr(f"progress.stage.{stage}") if stage in STAGES
                          else safe_text(stage.replace("_", " ").capitalize(), 55))
            changed = True
        elif line.startswith(("stage=completed ", "stage=skipped ", "stage=failed ")):
            stage = fields(line).get("name")
            key = self.current
            if (key is not None and key != "HOST" and
                    key not in self.completed and stage in LXC_PROGRESS_STAGES):
                # A stage counts once regardless of its outcome or duplicate
                # messages. Unknown/recovery/host stages cannot inflate totals.
                stages = self.stage_done.setdefault(key, set())
                if stage not in stages:
                    stages.add(stage)
                    changed = True
        elif line.startswith("custom_script=start "):
            name = fields(line).get("script", "")
            self.stage = tr("progress.running_script", script=safe_text(os.path.basename(name), 45))
            changed = True
        elif line.startswith("result_global "):
            self.global_status = fields(line).get("status")
            changed = True
        elif RESULT.match(line):
            info = fields(line)
            key = "HOST" if info.get("type") == "host" else info.get("vmid", "")
            if info.get("name") and key:
                self.names[key] = (tr("progress.host") if key == "HOST"
                                   else safe_text(info["name"].replace("_", " "), 38))
            if info.get("attempted") == "true" and info.get("status") in ("OK", "ERROR"):
                self.finish(key, info["status"], info.get("exit_code"))
                changed = True
            if info.get("status") == "ERROR" and info.get("result_detail"):
                detail = safe_text(unquote(info["result_detail"]), 180)
                self.notice(f"{self.name(key)}: {detail}")
                changed = True
        else:
            match = LXC_ID.match(line)
            if match:
                key, name = match.groups()
                self.names[key] = safe_text(name.replace("_", " ").replace("-", " "), 38)
                if self.mode == "lxc" and not self.completed and self.current is None:
                    self.begin(key)
                changed = True
            elif line.startswith("update=success ") or line.startswith("update=failed "):
                if self.mode != "bulk":
                    info = fields(line)
                    key = "HOST" if info.get("type") == "host" else info.get("vmid", self.target)
                    self.finish(key, "OK" if line.startswith("update=success ") else "ERROR",
                                info.get("exit_code"))
                    changed = True
            elif line.startswith(("WARNING:", "ERROR:", "NOTICE:", "FATAL:")):
                self.notice(line)
                changed = True
            elif line.startswith("reboot_required=yes "):
                if "type=host" in line:
                    self.notice(tr("progress.reboot_kernel"))
                    changed = True

        if changed:
            self.render(force=True)

    def notice(self, message):
        message = safe_text(message, 180)
        if message and message not in self.notices:
            self.notices.append(message)
            self.notices = self.notices[-6:]
            if not self.tty:
                sys.stdout.write("! " + message + "\n")
                sys.stdout.flush()

    def colored(self, text, color):
        if self.color:
            return f"\x1b[{color}m{text}\x1b[0m"
        return text

    def rows(self):
        cols, height = shutil.get_terminal_size((90, 24))
        width = max(48, cols - 1)
        finished = len(self.completed)
        total = self.total or 0
        # Completed targets contribute one full unit; an active LXC contributes
        # its distinct completed/skipped/failed stage count as a fraction.
        # The host remains a full unit only upon completion.
        progress_units = finished + sum(
            len(stages) / len(LXC_PROGRESS_STAGES)
            for key, stages in self.stage_done.items()
            if key not in self.completed and key != "HOST"
        )
        percent = min(100, int(progress_units * 100 / total)) if total else 0
        if finished < total:
            percent = min(99, percent)
        bar_width = max(10, min(26, width - 48))
        filled = int(bar_width * percent / 100)
        bar = "█" * filled + "░" * (bar_width - filled)
        if self.total is None:
            progress = tr("progress.preparing")
        else:
            progress = tr("progress.completed", done=finished, total=total, percentage=percent)
        lines = [
            self.colored(tr("progress.title"), "1;36"),
            f"{progress}   [{bar}]",
            "",
        ]
        capacity = max(2, min(14, height - 9))
        completed = list(self.completed.items())
        if len(completed) > capacity:
            lines.append(tr("progress.previous", count=len(completed) - capacity))
        for key, (status, duration, code) in completed[-capacity:]:
            marker = self.colored("✓", "32") if status == "OK" else self.colored("✗", "31")
            title = safe_text(self.name(key), max(12, width - 24))
            seconds = duration_text(duration)
            suffix = f" (exit {code})" if code and status == "ERROR" else ""
            lines.append(f"  {marker} {title} — {seconds}{suffix}")
        if self.current is not None:
            elapsed = duration_text(time.monotonic() - self.started[self.current])
            title = safe_text(self.name(self.current), max(12, width - 24))
            lines += ["", f"  {self.colored('→', '36')} {title} — {self.stage} · {elapsed}"]
        elif self.global_status:
            color = "32" if self.global_status == "SUCCESS" else "31"
            lines += ["", self.colored(tr("progress.result", status=self.global_status), color)]
        else:
            lines += ["", self.stage]
        if self.notices:
            lines += ["", tr("progress.warnings")]
            lines.extend("  ! " + m[:max(10, width - 5)] for m in self.notices[-2:])
        return lines, width

    def render(self, force=False):
        now = time.monotonic()
        if not force and now - self.last_output < 0.9:
            return
        lines, width = self.rows()
        if not self.tty:
            snapshot = (self.current, self.stage, len(self.completed), self.global_status,
                        tuple(self.notices))
            if snapshot == self.last_snapshot:
                return
            if self.current is not None:
                text = f"Forge: {self.name(self.current)} — {self.stage}"
            elif self.completed:
                key = next(reversed(self.completed))
                status, duration, _ = self.completed[key]
                text = f"Forge: {self.name(key)} {status} ({duration_text(duration)})"
            else:
                text = tr("progress.plain.preflight")
            if self.global_status:
                text = tr("progress.plain.result", status=self.global_status)
            sys.stdout.write(text + "\n")
            sys.stdout.flush()
            self.last_snapshot = snapshot
            return

        if self.rendered_lines:
            sys.stdout.write(f"\x1b[{self.rendered_lines}A\r\x1b[0J")
        for row in lines:
            # Clip before colour rendering; own escape sequences are not user input.
            plain_length = len(CONTROL.sub("", row))
            if plain_length > width:
                row = row[:width - 1] + "…"
            sys.stdout.write("\x1b[2K" + row + "\n")
        sys.stdout.flush()
        self.rendered_lines = len(lines)
        self.last_output = now

    def close(self):
        if self.current is not None:
            self.stage = tr("progress.incomplete")
        self.render(force=True)
        if self.tty:
            sys.stdout.write("\n")
        if self.run_id:
            sys.stdout.write(tr("progress.details", run_id=safe_text(self.run_id, 80)) + "\n")
        if self.final_table_lines is not None:
            # Original spacing, links, version deltas and actionable failures:
            # no second table renderer, backup, update or log write is needed.
            sys.stdout.write("\n" + "\n".join(self.final_table_lines) + "\n")
        sys.stdout.flush()


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("bulk", "host", "lxc"):
        raise SystemExit("usage: progress.py bulk|host|lxc TARGET")
    dashboard = Progress(sys.argv[1], sys.argv[2])
    pending = bytearray()
    while True:
        readable, _, _ = select.select([sys.stdin.fileno()], [], [], 1.0)
        if not readable:
            dashboard.render()
            continue
        chunk = os.read(sys.stdin.fileno(), 65536)
        if not chunk:
            break
        for byte in chunk:
            if byte == 10:
                # Blank lines matter inside the final result table.
                dashboard.parse(bytes(pending))
                pending.clear()
            elif byte == 13:
                if pending:
                    dashboard.parse(bytes(pending))
                    pending.clear()
            elif len(pending) < 65536:
                pending.append(byte)
    if pending:
        dashboard.parse(bytes(pending))
    dashboard.close()


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, OSError) as exc:
        print(f"ERROR: Forge progress presenter failed: {exc}", file=sys.stderr)
        sys.exit(1)
