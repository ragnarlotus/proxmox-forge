#!/bin/bash
# Description: Provides Forge's shared fail() helper for reporting an error and terminating the calling script.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}
