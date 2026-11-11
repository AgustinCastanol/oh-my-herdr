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

@test "extras.txt pins exactly the reviewed plugins" {
  run entries "$EXTRAS"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "persiyanov/herdr-reviewr aede1794248fbfc3fc8f45ff77977a718aadbef0 persiyanov.reviewr curl,sha256sum|shasum
plannotator/herdr-annotate/lite a9973b43c1fc90044a9f15755e310e12b8465abb annotate pbcopy|wl-copy|xclip
devashish2203/herdr-worktrunk f9df9ba700b8a4f4d97ddfe3ea3eb345e80b880b worktrunk wt,fzf
kryptamine/herdr-auto-title 954b35dc692cbf212c9e45cb7dff9744290dae3b herdr.auto-title -" ]
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
