#!/usr/bin/env python3
"""Stream one stage to the terminal and to sanitized target/run logs.

Read the producer exactly once. Keep terminal redraws and colors, except the
CSI 3 J scrollback erase; write only finalized plain-text lines to the logs.
"""

import os
import sys


class TerminalFilter:
    def __init__(self):
        self.pending = bytearray()

    def feed(self, data):
        result = bytearray()
        for byte in data:
            while True:
                pending = bytes(self.pending)
                if not pending:
                    if byte == 0x1B:
                        self.pending.append(byte)
                    else:
                        result.append(byte)
                    break
                if pending == b"\x1b" and byte == 0x5B:
                    self.pending.append(byte)
                    break
                if pending == b"\x1b[" and byte == 0x33:
                    self.pending.append(byte)
                    break
                if pending == b"\x1b[3" and byte == 0x4A:
                    self.pending.clear()  # CSI 3 J erases terminal scrollback.
                    break
                result.extend(self.pending)
                self.pending.clear()
                # Reprocess the current byte (which may start a new escape).
        return bytes(result)

    def finish(self):
        result = bytes(self.pending)
        self.pending.clear()
        return result


class LogSanitizer:
    def __init__(self, emit):
        self.emit = emit
        self.line = bytearray()
        self.state = "text"
        self.pending_cr = False

    def finish_line(self):
        self.emit(bytes(self.line) + b"\n")
        self.line.clear()

    def feed(self, data):
        for byte in data:
            if self.pending_cr:
                self.pending_cr = False
                if byte == 0x0A:
                    self.finish_line()
                    continue
                self.line.clear()  # A bare CR replaces the previous redraw.

            if self.state == "osc":
                if byte == 0x07:
                    self.state = "text"
                elif byte == 0x1B:
                    self.state = "osc_esc"
                continue
            if self.state == "osc_esc":
                if byte in (0x5C, 0x07):
                    self.state = "text"
                elif byte != 0x1B:
                    self.state = "osc"
                continue
            if self.state == "csi":
                if 0x40 <= byte <= 0x7E:
                    self.state = "text"
                continue
            if self.state == "esc":
                if byte == 0x5B:
                    self.state = "csi"
                    continue
                if byte == 0x5D:
                    self.state = "osc"
                    continue
                if 0x40 <= byte <= 0x5F:
                    self.state = "text"
                    continue
                self.state = "text"

            if byte == 0x1B:
                self.state = "esc"
            elif byte == 0x0D:
                self.pending_cr = True
            elif byte == 0x0A:
                self.finish_line()
            elif byte == 0x08:
                if self.line:
                    self.line.pop()
            else:
                self.line.append(byte)

    def finish(self):
        if self.pending_cr or self.line:
            self.finish_line()


def append_file(path):
    flags = os.O_WRONLY | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0)
    return os.fdopen(os.open(path, flags), "wb")


def main(target_path, run_path):
    with append_file(target_path) as target:
        run_log = None
        if run_path and run_path != target_path:
            try:
                run_log = append_file(run_path)
            except OSError as exc:
                print(f"WARNING: cannot open Forge run log: {exc}", file=sys.stderr)

        target_error = None
        terminal_error = None

        def emit_line(payload):
            nonlocal target_error, run_log
            if target_error is not None:
                return
            try:
                target.write(payload)
                target.flush()
            except OSError as exc:
                target_error = exc
                print(f"ERROR: cannot write Forge target log: {exc}", file=sys.stderr)
                return
            if run_log is not None:
                try:
                    run_log.write(payload)
                    run_log.flush()
                except OSError as exc:
                    print(f"WARNING: cannot write Forge run log: {exc}", file=sys.stderr)
                    run_log.close()
                    run_log = None

        def show(payload):
            nonlocal terminal_error
            if payload and terminal_error is None:
                try:
                    sys.stdout.buffer.write(payload)
                    sys.stdout.buffer.flush()
                except OSError as exc:
                    terminal_error = exc
                    print(f"ERROR: cannot stream Forge terminal output: {exc}", file=sys.stderr)

        terminal = TerminalFilter()
        sanitizer = LogSanitizer(emit_line)
        try:
            while True:
                chunk = os.read(0, 4096)  # Return available pipe data, not a full buffer.
                if not chunk:
                    break
                show(terminal.feed(chunk))
                sanitizer.feed(chunk)
            show(terminal.finish())
            sanitizer.finish()
        finally:
            if run_log is not None:
                run_log.close()

        return 1 if target_error is not None or terminal_error is not None else 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: stream.py TARGET_LOG RUN_LOG")
    try:
        sys.exit(main(sys.argv[1], sys.argv[2]))
    except OSError as exc:
        print(f"ERROR: Forge output streaming failed: {exc}", file=sys.stderr)
        sys.exit(1)
