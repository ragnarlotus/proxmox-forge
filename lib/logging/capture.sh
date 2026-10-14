#!/bin/bash
# Description: Captures one update stage for the owning update orchestrator, streaming combined output to the terminal while preserving scrollback, writing a readable sanitized copy to the log, and preserving the command's real exit code.

set -u -o pipefail

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run it through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 4 ]] || fail "usage: capture.sh LOG_FILE STAGE -- COMMAND [ARGUMENT ...]"
log_file="$1"
stage="$2"
shift 2

[[ "$1" == -- ]] || fail "expected -- before command"
shift
[[ $# -ge 1 ]] || fail "command must not be empty"

[[ -f "$log_file" ]] || fail "log file does not exist: $log_file"
[[ -w "$log_file" ]] || fail "log file is not writable: $log_file"
[[ "$stage" =~ ^[a-z][a-z0-9_-]*$ ]] || fail "invalid stage '$stage'"
command -v mkfifo >/dev/null 2>&1 || fail "mkfifo is not available"
command -v mktemp >/dev/null 2>&1 || fail "mktemp is not available"
command -v python3 >/dev/null 2>&1 || fail "python3 is not available"
command -v tee >/dev/null 2>&1 || fail "tee is not available"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
write_script="$script_dir/write.sh"
[[ -r "$write_script" ]] || fail "log write helper is not readable: $write_script"

printf -v command_text '%q ' "$@"
command_text="${command_text% }"

bash "$write_script" "$log_file" INFO stage_start \
  "stage=$stage" "command=$command_text" || fail "could not record stage start"

started_at="$(date +%s)" || fail "could not create stage start timestamp"

capture_dir="$(mktemp -d)" || fail "could not create capture temporary directory"
log_pipe="$capture_dir/log.pipe"
mkfifo "$log_pipe" || {
  rmdir "$capture_dir" 2>/dev/null || true
  fail "could not create capture pipe"
}

cleanup_capture() {
  rm -f "$log_pipe"
  rmdir "$capture_dir" 2>/dev/null || true
}
trap cleanup_capture EXIT

# A separate consumer sanitizes the byte stream for the persistent log.
# Standalone CR means "rewrite this line", so only the latest visible version is
# kept in the log instead of turning every progress redraw into a fake new line.
LC_ALL=C python3 -u -c '
import os
import sys

src = sys.stdin.buffer
dst = sys.stdout.buffer
state = "text"
line = bytearray()
pending_cr = False

# The existing sanitizer remains the single source of log text. Fan out only
# finalized, control-free lines; do not alter the producer/terminal stream.
run_path, target_path = sys.argv[1:]
run_log = None
if run_path and run_path != target_path:
    try:
        fd = os.open(run_path, os.O_WRONLY | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0))
        run_log = os.fdopen(fd, "wb", buffering=0)
    except OSError as exc:
        print(f"WARNING: cannot open Forge run log: {exc}", file=sys.stderr)

def emit_line():
    global run_log
    payload = bytes(line) + bytes((0x0A,))
    dst.write(payload)
    dst.flush()
    if run_log is not None:
        try:
            run_log.write(payload)
        except OSError as exc:
            print(f"WARNING: cannot write Forge run log: {exc}", file=sys.stderr)
            run_log.close()
            run_log = None
    line.clear()

while True:
    chunk = src.read(4096)
    if not chunk:
        break

    for c in chunk:
        if pending_cr:
            if c == 0x0A:
                emit_line()
                pending_cr = False
                continue

            # A bare carriage return moves the cursor back to column zero. The
            # next bytes replace the current progress line rather than creating
            # a new one.
            line.clear()
            pending_cr = False

        if state == "osc":
            if c == 0x07:
                state = "text"
            elif c == 0x1B:
                state = "osc_esc"
            continue

        if state == "osc_esc":
            if c == 0x5C or c == 0x07:
                state = "text"
            elif c != 0x1B:
                state = "osc"
            continue

        if state == "csi":
            if 0x40 <= c <= 0x7E:
                state = "text"
            continue

        if state == "esc":
            if c == 0x5B:
                state = "csi"
                continue
            if c == 0x5D:
                state = "osc"
                continue
            if 0x40 <= c <= 0x5F:
                state = "text"
                continue
            state = "text"

        if c == 0x1B:
            state = "esc"
            continue
        if c == 0x0D:
            pending_cr = True
            continue
        if c == 0x0A:
            emit_line()
            continue
        if c == 0x08:
            if line:
                line.pop()
        else:
            line.append(c)

if pending_cr or line:
    emit_line()
if run_log is not None:
    run_log.close()
' "${FORGE_RUN_LOG:-}" "$log_file" <"$log_pipe" >>"$log_file" &
sanitize_pid=$!

# Preserve the producer terminal stream, including colors, CR redraws and normal
# screen clears, but suppress CSI 3 J. That sequence clears terminal scrollback;
# Community Scripts emits it as part of its header repaint, which would otherwise
# erase earlier Forge stages from an update-all run.
"$@" 2>&1 | tee "$log_pipe" | LC_ALL=C python3 -u -c '
import sys

src = sys.stdin.buffer
dst = sys.stdout.buffer
pending = bytearray()

while True:
    chunk = src.read(4096)
    if not chunk:
        break

    output = bytearray()

    for c in chunk:
        while True:
            if not pending:
                if c == 0x1B:
                    pending.append(c)
                else:
                    output.append(c)
                break

            if pending == bytes((0x1B,)):
                if c == 0x5B:
                    pending.append(c)
                    break
                output.extend(pending)
                pending.clear()
                continue

            if pending == bytes((0x1B, 0x5B)):
                if c == 0x33:
                    pending.append(c)
                    break
                output.extend(pending)
                pending.clear()
                continue

            if pending == bytes((0x1B, 0x5B, 0x33)):
                if c == 0x4A:
                    pending.clear()
                    break
                output.extend(pending)
                pending.clear()
                continue

    if output:
        dst.write(output)
        dst.flush()

if pending:
    dst.write(pending)
    dst.flush()
'
pipeline_status=("${PIPESTATUS[@]}")
command_status="${pipeline_status[0]}"
tee_status="${pipeline_status[1]}"
terminal_filter_status="${pipeline_status[2]}"

wait "$sanitize_pid"
sanitize_status=$?

trap - EXIT
cleanup_capture

finished_at="$(date +%s)" || finished_at="$started_at"
duration_seconds=$((finished_at - started_at))

if (( command_status != 0 )); then
  bash "$write_script" "$log_file" ERROR stage_end \
    "stage=$stage" "status=failed" "exit_code=$command_status" "duration_seconds=$duration_seconds" || \
    printf 'ERROR: could not record failed stage result in %s\n' "$log_file" >&2
  exit "$command_status"
fi

if (( sanitize_status != 0 )); then
  printf 'ERROR: output sanitization failed for stage %s (python3 exit code %s)\n' \
    "$stage" "$sanitize_status" >&2
  bash "$write_script" "$log_file" ERROR stage_end \
    "stage=$stage" "status=logging_failed" "exit_code=$sanitize_status" "duration_seconds=$duration_seconds" 2>/dev/null || true
  exit "$sanitize_status"
fi

if (( tee_status != 0 )); then
  printf 'ERROR: logging output failed for stage %s (tee exit code %s)\n' "$stage" "$tee_status" >&2
  bash "$write_script" "$log_file" ERROR stage_end \
    "stage=$stage" "status=logging_failed" "exit_code=$tee_status" "duration_seconds=$duration_seconds" 2>/dev/null || true
  exit "$tee_status"
fi

if (( terminal_filter_status != 0 )); then
  printf 'ERROR: terminal output filtering failed for stage %s (python3 exit code %s)\n' \
    "$stage" "$terminal_filter_status" >&2
  bash "$write_script" "$log_file" ERROR stage_end \
    "stage=$stage" "status=terminal_output_failed" "exit_code=$terminal_filter_status" "duration_seconds=$duration_seconds" 2>/dev/null || true
  exit "$terminal_filter_status"
fi

bash "$write_script" "$log_file" INFO stage_end \
  "stage=$stage" "status=success" "exit_code=0" "duration_seconds=$duration_seconds" || \
  fail "command succeeded but its final log record could not be written"

exit 0
