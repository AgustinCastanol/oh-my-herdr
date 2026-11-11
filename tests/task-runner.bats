#!/usr/bin/env bats
# Tests for plugins/task-runner. The script runs with a PATH of only test
# stubs and symlinks to the system tools it needs, so fzf, make, just, npm,
# and herdr are whatever a test puts there. The herdr stub (HERDR_BIN_PATH)
# records `pane split` and `pane run` calls in $STUB_LOG.

setup() {
  load helpers/common
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  PLUGIN_DIR="$REPO_ROOT/plugins/task-runner"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/task-runner"
  STUBS_DIR="$BATS_TEST_DIRNAME/stubs"
  STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  TEST_BIN="$BATS_TEST_TMPDIR/bin"
  SYSBIN="$BATS_TEST_TMPDIR/sysbin"
  : >"$STUB_LOG"
  mkdir -p "$TEST_BIN" "$SYSBIN"
  local tool
  # cat is for the herdr stub, not the plugin.
  for tool in sh awk sed jq cat; do
    ln -s "$(command -v "$tool")" "$SYSBIN/$tool"
  done
  RUN_ENV=()
}

# Copy a fixture project into the test directory and print its path.
project() {
  cp -R "$FIXTURES/$1" "$BATS_TEST_TMPDIR/$1"
  printf '%s\n' "$BATS_TEST_TMPDIR/$1"
}

# Run task-runner.sh with the curated PATH and the herdr stub.
run_task_runner() {
  run env -i \
    PATH="$TEST_BIN:$SYSBIN" \
    HERDR_BIN_PATH="$STUBS_DIR/herdr" \
    STUB_LOG="$STUB_LOG" \
    ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
    "$SYSBIN/sh" "$PLUGIN_DIR/task-runner.sh" "$@"
}

# The context herdr gives the popup: the pane that was focused and its cwd.
popup_context() {
  printf '{"workspace_id":"w1","tab_id":"w1:t1","focused_pane_id":"w1:p1","focused_pane_cwd":"%s","invocation_source":"api"}' "$1"
}

# --- Detection ------------------------------------------------------------

@test "package.json scripts run with npm when there is no lockfile, quoted when needed" {
  run_task_runner list "$(project npm)"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "npm run build
npm run test
npm run lint:fix
npm run 'two words'" ]
}

@test "the lockfile picks the package manager" {
  local manager
  for manager in pnpm yarn bun bun-text; do
    run_task_runner list "$(project "$manager")"
    echo "$manager: $output"
    [ "$status" -eq 0 ]
    case "$manager" in
      bun-text) [ "$output" = "bun run dev" ] ;;
      *) [ "$output" = "$manager run dev" ] ;;
    esac
  done
}

@test "Makefile targets skip variables, special, pattern, and variable targets" {
  run_task_runner list "$(project make)"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "make build
make test
make clean
make all
make install
make docs
make check" ]
}

@test "justfile recipes skip settings, aliases, assignments, and private recipes" {
  run_task_runner list "$(project just)"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "just build
just test
just deploy
just fmt" ]
}

@test "listing never runs make, just, a package manager, or any project code" {
  local dir tool
  dir="$(project hostile)"
  for tool in make just npm pnpm yarn bun; do
    ln -s "$STUBS_DIR/task-tool" "$TEST_BIN/$tool"
  done
  run_task_runner list "$dir"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "npm run pwn
npm run safe
make target
just recipe" ]
  [ ! -s "$STUB_LOG" ]
  [ -z "$(cd "$dir" && ls SENTINEL_* 2>/dev/null)" ]
}

@test "a directory without task files lists nothing" {
  run_task_runner list "$(project empty)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- Popup ----------------------------------------------------------------

@test "with fzf, the chosen task runs in a new split below the focused pane" {
  local dir
  dir="$(project npm)"
  ln -s "$STUBS_DIR/fzf" "$TEST_BIN/fzf"
  RUN_ENV=("HERDR_PLUGIN_CONTEXT_JSON=$(popup_context "$dir")" "STUB_FZF_PICK=npm run lint:fix")
  run_task_runner popup
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged_prefix "fzf "
  assert_logged "herdr pane split w1:p1 --direction down --cwd $dir"
  assert_logged "herdr pane run w1:p9 npm run lint:fix"
}

@test "without fzf, a numbered menu picks the task" {
  local dir
  dir="$(project npm)"
  RUN_ENV=("HERDR_PLUGIN_CONTEXT_JSON=$(popup_context "$dir")")
  run_task_runner popup <<<"4"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "  4) npm run 'two words'"
  assert_logged "herdr pane run w1:p9 npm run 'two words'"
}

@test "cancelling fzf runs nothing" {
  local dir
  dir="$(project npm)"
  ln -s "$STUBS_DIR/fzf" "$TEST_BIN/fzf"
  RUN_ENV=("HERDR_PLUGIN_CONTEXT_JSON=$(popup_context "$dir")" "STUB_FZF_CANCEL=1")
  run_task_runner popup
  [ "$status" -eq 0 ]
  refute_logged "herdr pane split"
}

@test "an empty or out-of-range answer in the numbered menu runs nothing" {
  local dir answer
  dir="$(project npm)"
  RUN_ENV=("HERDR_PLUGIN_CONTEXT_JSON=$(popup_context "$dir")")
  for answer in "" "9" "x"; do
    run_task_runner popup <<<"$answer"
    echo "answer '$answer': $output"
    [ "$status" -eq 0 ]
  done
  refute_logged "herdr pane split"
}

@test "with no tasks, the popup says so and waits for a key" {
  local dir
  dir="$(project empty)"
  RUN_ENV=("HERDR_PLUGIN_CONTEXT_JSON=$(popup_context "$dir")")
  run_task_runner popup <<<""
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "No tasks found in $dir"
  assert_output_contains "Press Enter to close."
  refute_logged "herdr pane split"
}

@test "without a focused pane in the context, the popup explains and runs nothing" {
  RUN_ENV=("HERDR_PLUGIN_CONTEXT_JSON={}")
  run_task_runner popup <<<""
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "no focused pane"
  refute_logged "herdr pane split"
}

@test "a failed split is reported and the task is not run" {
  local dir
  dir="$(project npm)"
  RUN_ENV=("HERDR_PLUGIN_CONTEXT_JSON=$(popup_context "$dir")" "STUB_HERDR_SPLIT_FAIL=1")
  run_task_runner popup <<<"1"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "Could not open a split next to pane w1:p1"
  refute_logged "herdr pane run"
}

@test "a split whose new pane cannot be read is rolled back" {
  local dir
  dir="$(project npm)"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1"}],"type":"pane_list"}}' >"$BATS_TEST_TMPDIR/before.json"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1"},{"pane_id":"w1:p9"}],"type":"pane_list"}}' >"$BATS_TEST_TMPDIR/after.json"
  RUN_ENV=("HERDR_PLUGIN_CONTEXT_JSON=$(popup_context "$dir")" "STUB_HERDR_SPLIT_UNREADABLE=1"
    "STUB_HERDR_PANE_LIST=$BATS_TEST_TMPDIR/before.json"
    "STUB_HERDR_PANE_LIST_AFTER_SPLIT=$BATS_TEST_TMPDIR/after.json")
  run_task_runner popup <<<"1"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr pane close w1:p9"
  refute_logged "herdr pane close w1:p1"
  refute_logged "herdr pane run"
  assert_output_contains "Could not open a split next to pane w1:p1"
}

# --- Action ---------------------------------------------------------------

@test "the open action opens the tasks popup" {
  run_task_runner open
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr plugin pane open --plugin oh-my-herdr.task-runner --entrypoint tasks"
}

# --- Manifest -------------------------------------------------------------

@test "the manifest declares jq, a popup pane, and an open action, all as argv" {
  run python3 -I -c '
import sys, tomllib
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
manifest = tomllib.loads(text)
assert manifest["id"] == "oh-my-herdr.task-runner", manifest["id"]
assert manifest["min_herdr_version"] == "0.9.0"
requires = [line for line in text.splitlines() if line.startswith("# Requires:")]
assert requires == ["# Requires: jq on PATH"], requires
(pane,) = manifest["panes"]
assert pane["id"] == "tasks" and pane["placement"] == "popup", pane
(action,) = manifest["actions"]
assert action["id"] == "open", action
for entry in (pane, action):
    command = entry["command"]
    assert isinstance(command, list) and all(isinstance(arg, str) for arg in command), command
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
  printf '%s' "$output" | jq -e '.result.plugins[] | select(.plugin_id == "oh-my-herdr.task-runner" and .enabled)'
}
