#!/usr/bin/env bats
# Tests for plugins/git-status. The plugin script runs with the herdr stub
# (tests/stubs/herdr) as HERDR_BIN_PATH, so every `pane report-metadata` call
# is recorded in $STUB_LOG; git and jq are the real tools. Event and pane
# fixtures in tests/fixtures/git-status are shaped like herdr 0.9.5 output.

setup() {
  load helpers/common
  command -v git >/dev/null 2>&1 || skip "git is not on PATH"
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  PLUGIN_DIR="$REPO_ROOT/plugins/git-status"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/git-status"
  STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  STATE_DIR="$BATS_TEST_TMPDIR/state"
  REPO="$BATS_TEST_TMPDIR/repo"
  PLAIN="$BATS_TEST_TMPDIR/plain"
  : >"$STUB_LOG"
  mkdir -p "$STATE_DIR" "$PLAIN"
  git init -q -b main "$REPO"
  printf 'one\n' >"$REPO/file"
  git -C "$REPO" add file
  git -C "$REPO" -c user.name=test -c user.email=test@example.com commit -q -m init
  PLUGIN_ENV=()
  PLUGIN_CONFIG="$BATS_TEST_TMPDIR/plugin-config"
  mkdir -p "$PLUGIN_CONFIG"
}

REPORT="herdr pane report-metadata w1:p1 --source oh-my-herdr.git-status"

# Print a fixture with @CWD@ (and @CWD2@) replaced by the given paths.
fixture() {
  sed -e "s|@CWD@|$2|g" -e "s|@CWD2@|${3:-}|g" "$FIXTURES/$1"
}

# Opt in to the dirty marker the way a user does: a show-dirty file in the
# plugin config directory.
enable_dirty_marker() {
  touch "$PLUGIN_CONFIG/show-dirty"
}

# Make $REPO hostile: its own config points core.fsmonitor, a clean filter,
# a process filter (defined through include.path, with "=" in its driver
# name, which a `git -c` override could not express), and hooks at scripts that
# create a file in $SENTINELS. Then change two tracked files without changing
# their size, so git has to compare contents, which is when filters run.
make_hostile_repo() {
  SENTINELS="$BATS_TEST_TMPDIR/sentinels"
  local bin="$BATS_TEST_TMPDIR/hostile-bin" kind
  mkdir -p "$SENTINELS" "$bin"
  for kind in fsmonitor clean process hook; do
    printf '#!/bin/sh\ntouch "%s/%s"\ncat\n' "$SENTINELS" "$kind" >"$bin/$kind.sh"
    chmod +x "$bin/$kind.sh"
  done
  printf 'file filter=evil\n*.md filter=other=x\n' >"$REPO/.gitattributes"
  printf 'notes\n' >"$REPO/notes.md"
  git -C "$REPO" add .gitattributes notes.md
  git -C "$REPO" -c user.name=test -c user.email=test@example.com commit -q -m attributes
  git -C "$REPO" config core.fsmonitor "$bin/fsmonitor.sh"
  git -C "$REPO" config filter.evil.clean "$bin/clean.sh"
  git -C "$REPO" config filter.evil.smudge cat
  git -C "$REPO" config core.hooksPath "$bin"
  printf '[filter "other=x"]\n\tprocess = %s\n\tclean = %s\n' "$bin/process.sh" "$bin/clean.sh" \
    >"$BATS_TEST_TMPDIR/included.cfg"
  git -C "$REPO" config include.path "$BATS_TEST_TMPDIR/included.cfg"
  sleep 1
  printf 'ONE\n' >"$REPO/file"
  printf 'NOTES\n' >"$REPO/notes.md"
}

# Run the plugin script the way herdr does: event name and event JSON in the
# environment, no inherited HERDR_* settings, the stub as the herdr binary.
# Usage: run_plugin MODE [EVENT [EVENT_JSON]]
run_plugin() {
  run env -u HERDR_SOCKET_PATH -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_CONFIG_PATH -u HERDR_SESSION \
    HERDR_BIN_PATH="$BATS_TEST_DIRNAME/stubs/herdr" \
    HERDR_PLUGIN_STATE_DIR="$STATE_DIR" \
    HERDR_PLUGIN_CONFIG_DIR="$PLUGIN_CONFIG" \
    HERDR_PLUGIN_EVENT="${2:-}" \
    HERDR_PLUGIN_EVENT_JSON="${3:-}" \
    STUB_LOG="$STUB_LOG" \
    ${PLUGIN_ENV[@]+"${PLUGIN_ENV[@]}"} \
    sh "$PLUGIN_DIR/git-status.sh" "$1"
}

# --- Events ---------------------------------------------------------------

@test "a new pane in a clean repo reports its branch with a TTL" {
  run_plugin event pane.created "$(fixture pane-created.json "$REPO")"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "$REPORT --token git=main --ttl-ms 600000"
}

@test "uncommitted changes show no marker unless the user opts in" {
  printf 'two\n' >>"$REPO/file"
  run_plugin event pane.created "$(fixture pane-created.json "$REPO")"
  [ "$status" -eq 0 ]
  assert_logged "$REPORT --token git=main --ttl-ms 600000"
}

@test "with the dirty marker on, uncommitted changes add a * to the branch" {
  enable_dirty_marker
  printf 'two\n' >>"$REPO/file"
  run_plugin event pane.created "$(fixture pane-created.json "$REPO")"
  [ "$status" -eq 0 ]
  assert_logged "$REPORT --token git=main* --ttl-ms 600000"
}

@test "by default no command a repository configures ever runs" {
  make_hostile_repo
  run_plugin event pane.created "$(fixture pane-created.json "$REPO")"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "$REPORT --token git=main --ttl-ms 600000"
  [ -z "$(ls -A "$SENTINELS")" ] || { ls "$SENTINELS"; return 1; }
}

@test "the opt-in dirty check still runs no fsmonitor, filter, or hook" {
  make_hostile_repo
  enable_dirty_marker
  run_plugin event pane.created "$(fixture pane-created.json "$REPO")"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "$REPORT --token git=main* --ttl-ms 600000"
  [ -z "$(ls -A "$SENTINELS")" ] || { ls "$SENTINELS"; return 1; }
}

@test "a detached HEAD shows the short commit" {
  git -C "$REPO" checkout -q --detach
  run_plugin event pane.created "$(fixture pane-created.json "$REPO")"
  [ "$status" -eq 0 ]
  assert_logged "$REPORT --token git=@$(git -C "$REPO" rev-parse --short HEAD) --ttl-ms 600000"
}

# Put a git first on PATH that reports version $1 and otherwise runs the
# real git.
use_git_reporting_version() {
  local bin="$BATS_TEST_TMPDIR/git-$1"
  mkdir -p "$bin"
  ln -s "$BATS_TEST_DIRNAME/stubs/git-version" "$bin/git"
  PLUGIN_ENV+=("PATH=$bin:$PATH" "STUB_GIT_VERSION=$1" "STUB_REAL_GIT=$(command -v git)")
}

@test "the dirty check is skipped when git is older than 2.31" {
  make_hostile_repo
  enable_dirty_marker
  use_git_reporting_version 2.30.2
  run_plugin event pane.created "$(fixture pane-created.json "$REPO")"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "$REPORT --token git=main --ttl-ms 600000"
  assert_output_contains "git-status: git 2.30.2 is older than 2.31; showing the branch without the dirty marker"
  [ -z "$(ls -A "$SENTINELS")" ] || { ls "$SENTINELS"; return 1; }
}

@test "the dirty check is skipped when the git version cannot be read" {
  enable_dirty_marker
  printf 'two\n' >>"$REPO/file"
  use_git_reporting_version unknown
  run_plugin event pane.created "$(fixture pane-created.json "$REPO")"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "$REPORT --token git=main --ttl-ms 600000"
  assert_output_contains "git-status: could not read the git version"
}

@test "a pane outside a git repo clears the token" {
  run_plugin event pane.created "$(fixture pane-created.json "$PLAIN")"
  [ "$status" -eq 0 ]
  assert_logged "$REPORT --clear-token git"
  refute_logged "$REPORT --token"
}

@test "a pane whose cwd herdr does not know keeps its token" {
  printf '%s\n' '{"id":"cli:pane:get","result":{"pane":{"pane_id":"w1:p1","cwd":null,"foreground_cwd":null},"type":"pane_info"}}' \
    >"$BATS_TEST_TMPDIR/pane-get.json"
  PLUGIN_ENV=("STUB_HERDR_PANE_GET=$BATS_TEST_TMPDIR/pane-get.json")
  run_plugin event pane.created "$(cat "$FIXTURES/pane-created-no-cwd.json")"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr pane get w1:p1"
  refute_logged "herdr pane report-metadata"
  assert_output_contains "git-status: no working directory for pane w1:p1"
}

@test "a failed pane lookup leaves the token alone" {
  run_plugin event pane.focused "$(cat "$FIXTURES/pane-focused.json")"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr pane get w1:p2"
  refute_logged "herdr pane report-metadata"
  assert_output_contains "git-status: no working directory for pane w1:p2"
}

@test "a failed report does not start the debounce window" {
  PLUGIN_ENV=("STUB_HERDR_REPORT_FAIL=1")
  run_plugin event pane.created "$(fixture pane-created.json "$REPO")"
  [ "$status" -eq 0 ]
  : >"$STUB_LOG"
  PLUGIN_ENV=()
  run_plugin event pane.created "$(fixture pane-created.json "$REPO")"
  [ "$status" -eq 0 ]
  assert_logged "$REPORT --token git=main --ttl-ms 600000"
}

@test "a focused pane is looked up with pane get, since the event has no cwd" {
  fixture pane-get.json "$REPO" >"$BATS_TEST_TMPDIR/pane-get.json"
  PLUGIN_ENV=("STUB_HERDR_PANE_GET=$BATS_TEST_TMPDIR/pane-get.json")
  run_plugin event pane.focused "$(cat "$FIXTURES/pane-focused.json")"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr pane get w1:p2"
  assert_logged "herdr pane report-metadata w1:p2 --source oh-my-herdr.git-status --token git=main --ttl-ms 600000"
}

@test "a pane refreshed moments ago is skipped" {
  run_plugin event pane.created "$(fixture pane-created.json "$REPO")"
  [ "$status" -eq 0 ]
  : >"$STUB_LOG"
  run_plugin event pane.created "$(fixture pane-created.json "$REPO")"
  [ "$status" -eq 0 ]
  refute_logged "herdr pane report-metadata"
}

# --- Startup and the refresh action ---------------------------------------

@test "all mode reports every pane from pane list" {
  fixture pane-list.json "$REPO" "$PLAIN" >"$BATS_TEST_TMPDIR/pane-list.json"
  PLUGIN_ENV=("STUB_HERDR_PANE_LIST=$BATS_TEST_TMPDIR/pane-list.json")
  run_plugin all startup
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "$REPORT --token git=main --ttl-ms 600000"
  assert_logged "herdr pane report-metadata w1:p2 --source oh-my-herdr.git-status --clear-token git"
}

# --- Failures stay quiet --------------------------------------------------

@test "a failing pane list is logged and reports nothing" {
  PLUGIN_ENV=("STUB_HERDR_PANE_LIST_FAIL=1")
  run_plugin all startup
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "git-status: could not list panes"
  refute_logged "herdr pane report-metadata"
}

@test "a missing jq exits 0 with one log line and reports nothing" {
  local bin="$BATS_TEST_TMPDIR/nojq"
  mkdir -p "$bin"
  ln -s "$(command -v git)" "$bin/git"
  run env -i PATH="$bin" HERDR_BIN_PATH="$BATS_TEST_DIRNAME/stubs/herdr" STUB_LOG="$STUB_LOG" \
    "$(command -v sh)" "$PLUGIN_DIR/git-status.sh" all
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "git-status: jq is not on PATH; nothing to do" ]
  [ ! -s "$STUB_LOG" ]
}

@test "a failing herdr call is logged and the plugin still exits 0" {
  PLUGIN_ENV=("STUB_HERDR_REPORT_FAIL=1")
  run_plugin event pane.created "$(fixture pane-created.json "$REPO")"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "git-status: could not report git status for pane w1:p1"
}

@test "malformed event JSON exits 0 with a log line" {
  run_plugin event pane.created "not json"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "git-status: no pane in the event"
}

# --- Manifest -------------------------------------------------------------

@test "the manifest declares its requirements and only argv commands" {
  run python3 -I -c '
import sys, tomllib
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
manifest = tomllib.loads(text)
assert manifest["id"] == "oh-my-herdr.git-status", manifest["id"]
assert manifest["min_herdr_version"] == "0.9.0"
requires = [line for line in text.splitlines() if line.startswith("# Requires:")]
assert requires == ["# Requires: git on PATH, jq on PATH"], requires
entries = manifest["startup"] + manifest["events"] + manifest["actions"]
for entry in entries:
    command = entry["command"]
    assert isinstance(command, list) and all(isinstance(arg, str) for arg in command), command
assert sorted(event["on"] for event in manifest["events"]) == ["pane.created", "pane.focused"]
' "$PLUGIN_DIR/herdr-plugin.toml"
  echo "$output"
  [ "$status" -eq 0 ]
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
  printf '%s' "$output" | jq -e '.result.plugins[] | select(.plugin_id == "oh-my-herdr.git-status" and .enabled)'
}
