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
command -v python3 >/dev/null 2>&1 || fail "python3 is not available"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "could not determine script directory"
write_script="$script_dir/write.sh"
stream_script="$script_dir/stream.py"
[[ -r "$write_script" ]] || fail "log write helper is not readable: $write_script"
[[ -r "$stream_script" ]] || fail "output stream helper is not readable: $stream_script"

printf -v command_text '%q ' "$@"
command_text="${command_text% }"

bash "$write_script" "$log_file" INFO stage_start \
  "stage=$stage" "command=$command_text" || fail "could not record stage start"

printf 'stage=start name=%s\n' "$stage"

started_at="$(date +%s)" || fail "could not create stage start timestamp"

# Consume each byte once, stream immediately to the terminal, and append
# sanitized plain-text lines to the target and run logs.
"$@" 2>&1 | LC_ALL=C python3 -u "$stream_script" "$log_file" "${FORGE_RUN_LOG:-}"
pipeline_status=("${PIPESTATUS[@]}")
command_status="${pipeline_status[0]}"
stream_status="${pipeline_status[1]}"

finished_at="$(date +%s)" || finished_at="$started_at"
duration_seconds=$((finished_at - started_at))

if (( command_status != 0 )); then
  bash "$write_script" "$log_file" ERROR stage_end \
    "stage=$stage" "status=failed" "exit_code=$command_status" "duration_seconds=$duration_seconds" || \
    printf 'ERROR: could not record failed stage result in %s\n' "$log_file" >&2
  exit "$command_status"
fi

if (( stream_status != 0 )); then
  printf 'ERROR: stage output streaming failed for %s (exit code %s)\n' \
    "$stage" "$stream_status" >&2
  bash "$write_script" "$log_file" ERROR stage_end \
    "stage=$stage" "status=logging_failed" "exit_code=$stream_status" "duration_seconds=$duration_seconds" 2>/dev/null || true
  exit "$stream_status"
fi

bash "$write_script" "$log_file" INFO stage_end \
  "stage=$stage" "status=success" "exit_code=0" "duration_seconds=$duration_seconds" || \
  fail "command succeeded but its final log record could not be written"

exit 0
