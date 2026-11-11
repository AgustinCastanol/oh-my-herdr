#!/usr/bin/env bats
# Checks for extras.txt: the curated third-party herdr plugins install.sh
# installs only with --with-extras, each pinned to a reviewed commit. Nothing
# here installs, builds, or runs a third-party plugin.

setup() {
  load helpers/common
  EXTRAS="$REPO_ROOT/extras.txt"
}

# Print "source ref id requires" for every entry (comments and blanks skipped).
entries() {
  awk '!/^[ \t]*(#|$)/ { print $1, $2, $3, $4 }' "$1"
}

# Fail, printing the offending lines, unless every entry of the file has a
# ref of exactly 40 hex characters and a description after the requirements.
lint_refs() {
  awk '
    /^[ \t]*(#|$)/ { next }
    $2 !~ /^[0-9a-fA-F]+$/ || length($2) != 40 || NF < 5 { print NR ": " $0; bad = 1 }
    END { exit bad }
  ' "$1"
}

# Print the SHA-256 of what was reviewed: "source ref id requires" of every
# entry. extras.txt is the single source of the pins; this hash records the
# reviewed set without repeating it, so changing a pin is a deliberate step.
# `make extras-hash` runs the same helper.
reviewed_hash() {
  sh "$REPO_ROOT/tests/helpers/extras-hash.sh" "$1"
}

@test "extras.txt matches the reviewed set recorded in tests/fixtures/extras-reviewed.sha256" {
  local recorded
  recorded="$(sed -n 's/^\([0-9a-f]\{64\}\).*/\1/p' "$BATS_TEST_DIRNAME/fixtures/extras-reviewed.sha256")"
  run reviewed_hash "$EXTRAS"
  echo "extras.txt hashes to $output; recorded: $recorded"
  [ "$status" -eq 0 ]
  [ -n "$recorded" ]
  [ "$output" = "$recorded" ]
}

@test "make extras-hash prints the hash these tests check" {
  command -v make >/dev/null 2>&1 || skip "make is not on PATH"
  local expected
  expected="$(reviewed_hash "$EXTRAS")"
  [ -n "$expected" ]
  run env -u MAKEFLAGS -u MAKELEVEL make -s -C "$REPO_ROOT" --no-print-directory extras-hash
  echo "make: $output; helper: $expected"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "the extras hash covers source, ref, id, and requirements but not the description" {
  local changed="$BATS_TEST_TMPDIR/extras.txt" original
  original="$(reviewed_hash "$EXTRAS")"
  awk '!/^[ \t]*(#|$)/ { $5 = "a different description" } { print }' "$EXTRAS" >"$changed"
  [ "$(reviewed_hash "$changed")" = "$original" ]
  awk '!/^[ \t]*(#|$)/ && !done { $4 = $4 ",git"; done = 1 } { print }' "$EXTRAS" >"$changed"
  [ "$(reviewed_hash "$changed")" != "$original" ]
}

@test "the README extras table shows each pinned commit" {
  local source ref
  while read -r source ref _; do
    grep -q "| \`$source\` |.*| \`${ref:0:7}\`" "$REPO_ROOT/README.md" ||
      { echo "README.md has no row for $source at ${ref:0:7}"; return 1; }
  done < <(entries "$EXTRAS")
}

@test "every extra has a 40-character hex ref and a description" {
  run lint_refs "$EXTRAS"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the ref lint rejects a ref that is not exactly 40 hex characters" {
  local bad="$BATS_TEST_TMPDIR/extras.txt" ref
  for ref in 0123456789abcdef0123456789abcdef0123456 \
    0123456789abcdef0123456789abcdef012345678 \
    0123456789abcdef0123456789abcdef0123456g main; do
    printf 'owner/repo %s some.id - description\n' "$ref" >"$bad"
    run lint_refs "$bad"
    echo "$ref: $output"
    [ "$status" -eq 1 ]
  done
}
