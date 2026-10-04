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
command -v perl >/dev/null 2>&1 || fail "perl is not available"
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
LC_ALL=C perl -e '
  use strict;
  use warnings;

  binmode STDIN;
  binmode STDOUT;
  $| = 1;

  my $state = "text";
  my $line = "";
  my $pending_cr = 0;

  sub emit_line {
    print $line, "\n";
    $line = "";
  }

  sub append_text {
    my ($c) = @_;
    if ($c eq "\b") {
      chop $line if length $line;
    } else {
      $line .= $c;
    }
  }

  while (read(STDIN, my $chunk, 4096)) {
    for my $c (split //, $chunk) {
      if ($pending_cr) {
        if ($c eq "\n") {
          emit_line();
          $pending_cr = 0;
          next;
        }

        # A bare carriage return moves the cursor back to column zero. The next
        # bytes replace the current progress line rather than creating a new one.
        $line = "";
        $pending_cr = 0;
      }

      if ($state eq "osc") {
        if ($c eq "\a") {
          $state = "text";
        } elsif ($c eq "\e") {
          $state = "osc_esc";
        }
        next;
      }

      if ($state eq "osc_esc") {
        if ($c eq "\\" || $c eq "\a") {
          $state = "text";
        } elsif ($c ne "\e") {
          $state = "osc";
        }
        next;
      }

      if ($state eq "csi") {
        my $ord = ord($c);
        $state = "text" if $ord >= 0x40 && $ord <= 0x7e;
        next;
      }

      if ($state eq "esc") {
        if ($c eq "[") {
          $state = "csi";
          next;
        }
        if ($c eq "]") {
          $state = "osc";
          next;
        }

        my $ord = ord($c);
        if ($ord >= 0x40 && $ord <= 0x5f) {
          $state = "text";
          next;
        }

        $state = "text";
      }

      if ($c eq "\e") {
        $state = "esc";
        next;
      }
      if ($c eq "\r") {
        $pending_cr = 1;
        next;
      }
      if ($c eq "\n") {
        emit_line();
        next;
      }

      append_text($c);
    }
  }

  if ($pending_cr || length $line) {
    emit_line();
  }
' <"$log_pipe" >>"$log_file" &
sanitize_pid=$!

# Preserve the producer terminal stream, including colors, CR redraws and normal
# screen clears, but suppress CSI 3 J. That sequence clears terminal scrollback;
# Community Scripts emits it as part of its header repaint, which would otherwise
# erase earlier Forge stages from an update-all run.
"$@" 2>&1 | tee "$log_pipe" | LC_ALL=C perl -e '
  use strict;
  use warnings;

  binmode STDIN;
  binmode STDOUT;
  $| = 1;

  my $pending = "";

  while (read(STDIN, my $chunk, 4096)) {
    for my $c (split //, $chunk) {
      while (1) {
        if ($pending eq "") {
          if ($c eq "\e") {
            $pending = $c;
          } else {
            print $c;
          }
          last;
        }

        if ($pending eq "\e") {
          if ($c eq "[") {
            $pending .= $c;
            last;
          }
          print $pending;
          $pending = "";
          next;
        }

        if ($pending eq "\e[") {
          if ($c eq "3") {
            $pending .= $c;
            last;
          }
          print $pending;
          $pending = "";
          next;
        }

        if ($pending eq "\e[3") {
          if ($c eq "J") {
            $pending = "";
            last;
          }
          print $pending;
          $pending = "";
          next;
        }
      }
    }
  }

  print $pending if length $pending;
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
  printf 'ERROR: output sanitization failed for stage %s (perl exit code %s)\n' \
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
  printf 'ERROR: terminal output filtering failed for stage %s (perl exit code %s)\n' \
    "$stage" "$terminal_filter_status" >&2
  bash "$write_script" "$log_file" ERROR stage_end \
    "stage=$stage" "status=terminal_output_failed" "exit_code=$terminal_filter_status" "duration_seconds=$duration_seconds" 2>/dev/null || true
  exit "$terminal_filter_status"
fi

bash "$write_script" "$log_file" INFO stage_end \
  "stage=$stage" "status=success" "exit_code=0" "duration_seconds=$duration_seconds" || \
  fail "command succeeded but its final log record could not be written"

exit 0
