#!/bin/sh
# shellcheck shell=sh
#
# Print the SHA-256 of the reviewed extras in extras file $1 (default
# extras.txt): "source ref id requires" of every entry, comments and blank
# lines skipped. `make extras-hash` and tests/extras.bats both run this, so
# the recorded tests/fixtures/extras-reviewed.sha256 has one definition.
set -eu

awk '!/^[ \t]*(#|$)/ { print $1, $2, $3, $4 }' "${1:-extras.txt}" |
  python3 -I -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
