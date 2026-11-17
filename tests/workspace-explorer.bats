#!/usr/bin/env bats
# Tests for plugins/workspace-explorer. They browse a directory tree the test
# builds, with a PATH of only test stubs and symlinks to the tools the plugin
# needs. git is a stub that marks the test as failed if anything runs it:
# browsing must never run a program in a browsed directory. herdr is the
# stub, which logs every call.
#
# Each test runs in its own subshell, so changing RUN_ENV in one test is
# meant to stay local to it.
# shellcheck disable=SC2030,SC2031

setup() {
  load helpers/common
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  PLUGIN_DIR="$REPO_ROOT/plugins/workspace-explorer"
  STUBS_DIR="$BATS_TEST_DIRNAME/stubs"
  STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  TEST_BIN="$BATS_TEST_TMPDIR/bin"
  SYSBIN="$BATS_TEST_TMPDIR/sysbin"
  : >"$STUB_LOG"
  mkdir -p "$TEST_BIN" "$SYSBIN"
  local tool
  for tool in sh awk sed jq cat tr sort; do
    ln -s "$(command -v "$tool")" "$SYSBIN/$tool"
  done
  GIT_CALLED="$BATS_TEST_TMPDIR/git-called"
  printf '#!/bin/sh\n: >"%s"\nexit 1\n' "$GIT_CALLED" >"$TEST_BIN/git"
  chmod +x "$TEST_BIN/git"
  # The tree to browse; its real path, since the plugin shows real paths.
  mkdir -p "$BATS_TEST_TMPDIR/tree"
  TREE="$(cd "$BATS_TEST_TMPDIR/tree" && pwd -P)"
  mkdir -p "$TREE/alpha/inner" "$TREE/beta/.git" "$TREE/.hidden" "$TREE/with space" "$TREE/locked" "$TREE/bad
name"
  printf 'x\n' >"$TREE/a.txt"
  printf 'x\n' >"$TREE/c file.txt"
  ln -s alpha "$TREE/link-to-alpha"
  chmod 000 "$TREE/locked"
  RUN_ENV=()
}

teardown() {
  chmod 755 "$TREE/locked" 2>/dev/null || true
  # Browsing never runs git (or anything else) in a browsed directory.
  if [ -e "$GIT_CALLED" ]; then
    echo "git was run"
    return 1
  fi
}

# Run the explorer popup like herdr does after the "open" action on a pane
# whose directory is $START (default: the tree).
run_explorer() {
  run env -i \
    PATH="$TEST_BIN:$SYSBIN" \
    HOME="${EXPLORER_HOME:-$BATS_TEST_TMPDIR}" \
    HERDR_BIN_PATH="$STUBS_DIR/herdr" \
    OMH_EXPLORER_CWD="${START-$TREE}" \
    STUB_LOG="$STUB_LOG" \
    ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
    "$SYSBIN/sh" "$PLUGIN_DIR/workspace-explorer.sh" browse
}

# Each "Directory: ..." heading in $output. Input is not echoed, so a
# heading can follow the previous prompt on the same line.
directories() { printf '%s\n' "$output" | grep -o 'Directory: .*'; }

# The numbered menu lines of the last listing in $output.
last_listing() {
  printf '%s\n' "$output" | awk '/Directory: / { block = "" } / *[0-9]+\) / { block = block $0 "\n" } END { printf "%s", block }'
}

@test "the listing starts with ../, then directories, then files, and marks projects and symlinks" {
  run_explorer <<<"q"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "Directory: $TREE"
  [ "$(last_listing)" = "$(printf '%s\n' \
    '  1) ../' \
    '  2) alpha/' \
    '  3) beta/  [project]' \
    '  4) link-to-alpha/  [symlink]' \
    '  5) locked/' \
    '  6) with space/' \
    '  7) a.txt' \
    '  8) c file.txt')" ]
  assert_output_contains "1 entry with a line break or tab in its name is not shown"
}

@test "names with a tab are skipped and counted with names with a line break" {
  : >"$TREE/tab$(printf '\t')name"
  run_explorer <<<"q"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "2 entries with a line break or tab in their names are not shown"
  refute_output_contains "tab"$'\t'
}

@test "hidden entries are shown after h and hidden again after another h" {
  run_explorer <<<$'h\nh\nq'
  echo "$output"
  printf '%s\n' "$output" | grep -qF ') .hidden/'
  refute_output_contains ") .git"
  run_explorer <<<"q"
  refute_output_contains ".hidden/"
}

@test "a directory it cannot read is reported and the listing stays where it was" {
  run_explorer <<<$'5\nq'
  echo "$output"
  assert_output_contains "Cannot open $TREE/locked"
  [ "$(directories | grep -cxF "Directory: $TREE")" = 2 ]
}

@test "entering a directory and going back up with - or ../" {
  run_explorer <<<$'2\n-\n6\n1\nq'
  echo "$output"
  [ "$(directories)" = "$(printf '%s\n' \
    "Directory: $TREE" "Directory: $TREE/alpha" "Directory: $TREE" \
    "Directory: $TREE/with space" "Directory: $TREE")" ]
}

@test "going up stops at the root" {
  START=/
  run_explorer <<<$'-\nq'
  echo "$output"
  [ "$(directories | grep -cx 'Directory: /')" = 2 ]
  assert_output_contains "Already at /"
}

@test "without a pane directory it starts in HOME" {
  START=''
  EXPLORER_HOME="$TREE/with space"
  run_explorer <<<"q"
  echo "$output"
  assert_output_contains "Directory: $TREE/with space"
}

# --- Opening a workspace --------------------------------------------------

@test "o N opens a new workspace at that directory when none is there" {
  run_explorer <<<"o 2"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr workspace create --cwd $TREE/alpha --label alpha --focus"
  refute_logged "herdr workspace focus"
}

@test "o alone opens a workspace at the current directory" {
  run_explorer <<<$'6\no'
  echo "$output"
  assert_logged "herdr workspace create --cwd $TREE/with space --label with space --focus"
}

@test "a workspace whose pane is already in that directory is focused instead" {
  local panes="$BATS_TEST_TMPDIR/panes.json"
  printf '{"result":{"panes":[{"pane_id":"w5:p1","workspace_id":"w5","cwd":"%s"},{"pane_id":"w1:p1","workspace_id":"w1","cwd":"/elsewhere"}],"type":"pane_list"}}\n' \
    "$TREE/link-to-alpha" >"$panes"
  RUN_ENV+=("STUB_HERDR_PANE_LIST=$panes")
  run_explorer <<<"o 2"
  echo "$output"
  assert_logged "herdr workspace focus w5"
  refute_logged "herdr workspace create"
}

@test "a new workspace is labeled parent/name when another one already uses the name" {
  local workspaces="$BATS_TEST_TMPDIR/workspaces.json"
  printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","label":"alpha"}],"type":"workspace_list"}}' >"$workspaces"
  RUN_ENV+=("STUB_HERDR_WORKSPACES=$workspaces")
  run_explorer <<<"o 2"
  echo "$output"
  assert_logged "herdr workspace create --cwd $TREE/alpha --label tree/alpha --focus"
}

@test "with fzf, Enter descends and ctrl-o opens a workspace at the highlighted directory" {
  ln -s "$STUBS_DIR/fzf" "$TEST_BIN/fzf"
  printf '\talpha/\nctrl-o\tinner/\n' >"$BATS_TEST_TMPDIR/steps"
  RUN_ENV+=("STUB_FZF_STEPS=$BATS_TEST_TMPDIR/steps")
  run_explorer </dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged_prefix "fzf "
  grep -q -- '--expect=ctrl-o,ctrl-t' "$STUB_LOG"
  assert_logged "herdr workspace create --cwd $TREE/alpha/inner --label inner --focus"
}

@test "with fzf, ctrl-o on ../ opens a workspace at the current directory" {
  ln -s "$STUBS_DIR/fzf" "$TEST_BIN/fzf"
  printf 'ctrl-o\t../\n' >"$BATS_TEST_TMPDIR/steps"
  RUN_ENV+=("STUB_FZF_STEPS=$BATS_TEST_TMPDIR/steps")
  run_explorer </dev/null
  assert_logged "herdr workspace create --cwd $TREE --label tree --focus"
}

# --- Action, manifest, module, and safety ---------------------------------

@test "the open action opens the explorer popup at the focused pane's directory" {
  run env -i PATH="$TEST_BIN:$SYSBIN" HERDR_BIN_PATH="$STUBS_DIR/herdr" STUB_LOG="$STUB_LOG" \
    HERDR_PLUGIN_CONTEXT_JSON="{\"focused_pane_id\":\"w1:p1\",\"focused_pane_cwd\":\"$TREE\"}" \
    "$SYSBIN/sh" "$PLUGIN_DIR/workspace-explorer.sh" open
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr plugin pane open --plugin oh-my-herdr.workspace-explorer --entrypoint explorer --env OMH_EXPLORER_CWD=$TREE"
}

@test "the manifest declares jq, the explorer popup, and the open action" {
  run grep -q '^# Requires: jq on PATH' "$PLUGIN_DIR/herdr-plugin.toml"
  [ "$status" -eq 0 ]
  run python3 -I -c '
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    manifest = tomllib.load(handle)
assert manifest["id"] == "oh-my-herdr.workspace-explorer", manifest["id"]
assert manifest["min_herdr_version"] == "0.9.0"
(pane,) = manifest["panes"]
assert pane["id"] == "explorer" and pane["placement"] == "popup", pane
assert pane["command"] == ["sh", "workspace-explorer.sh", "browse"], pane
(action,) = manifest["actions"]
assert action["id"] == "open" and action["command"] == ["sh", "workspace-explorer.sh", "open"], action
assert "startup" not in manifest and "events" not in manifest and "build" not in manifest
' "$PLUGIN_DIR/herdr-plugin.toml"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the module binds prefix+ctrl+o to the explorer" {
  run grep -q '^# Requires: jq on PATH' "$REPO_ROOT/config/modules/workspace-explorer.toml"
  [ "$status" -eq 0 ]
  run python3 -I -c '
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    (command,) = tomllib.load(handle)["keys"]["command"]
assert command["key"] == "prefix+ctrl+o", command["key"]
assert command["type"] == "plugin_action", command["type"]
assert command["command"] == "oh-my-herdr.workspace-explorer.open", command["command"]
assert command["description"], command
' "$REPO_ROOT/config/modules/workspace-explorer.toml"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the plugin changes no files: no rm, mv, cp, mkdir, touch, or writes" {
  run grep -nE '(^|[^a-z_-])(rm|mv|cp|mkdir|touch|ln|chmod|git) |[^2]>[^&/]|>>' "$PLUGIN_DIR/workspace-explorer.sh"
  echo "$output"
  [ "$status" -eq 1 ]
}

@test "real herdr links the plugin and lists it" {
  command -v herdr >/dev/null 2>&1 || skip "herdr is not on PATH"
  local home
  home="$(mktemp -d "$BATS_TEST_TMPDIR/home.XXXXXX")"
  # A short relative socket path keeps herdr's socket under the throwaway
  # HOME and within the platform's socket path length limit.
  run sh -c 'cd "$1" && shift && env -u HERDR_SOCKET_PATH -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_CONFIG_PATH -u HERDR_SESSION \
    HOME="$PWD" XDG_CONFIG_HOME="$PWD/.config" XDG_STATE_HOME="$PWD/.local/state" XDG_DATA_HOME="$PWD/.local/share" \
    HERDR_CONFIG_PATH="$PWD/.config/herdr/config.toml" HERDR_SOCKET_PATH=./h.sock \
    sh -c "herdr plugin link \"\$1\" >/dev/null && herdr plugin list --json" sh "$1"' sh "$home" "$PLUGIN_DIR"
  echo "$output"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.result.plugins[] | select(.plugin_id == "oh-my-herdr.workspace-explorer" and .enabled)'
}

@test "quitting, with q or with Esc in fzf, opens and focuses nothing" {
  run_explorer <<<"q"
  [ "$status" -eq 0 ]
  refute_logged "herdr workspace"
  ln -s "$STUBS_DIR/fzf" "$TEST_BIN/fzf"
  RUN_ENV+=("STUB_FZF_CANCEL=1")
  run_explorer </dev/null
  [ "$status" -eq 0 ]
  refute_logged "herdr workspace"
}

@test "an fzf that fails (exit 2, e.g. a bad FZF_DEFAULT_OPTS) ends the explorer instead of reopening it" {
  cat >"$TEST_BIN/fzf" <<STUB
#!/bin/sh
n=\$((\$(cat "$BATS_TEST_TMPDIR/fzf-calls" 2>/dev/null || echo 0) + 1))
printf '%s\n' "\$n" >"$BATS_TEST_TMPDIR/fzf-calls"
[ "\$n" -le 1 ] || exit 130
echo 'unknown option: --no-such-option' >&2
exit 2
STUB
  chmod +x "$TEST_BIN/fzf"
  run_explorer </dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/fzf-calls")" = 1 ]
  refute_logged "herdr workspace"
}
