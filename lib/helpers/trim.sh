#!/bin/bash
# Description: Removes leading and trailing whitespace from one input value without altering its internal content.

set -u

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: trim.sh VALUE"

value="$1"
value="${value#"${value%%[![:space:]]*}"}"
value="${value%"${value##*[![:space:]]}"}"

printf '%s' "$value"
