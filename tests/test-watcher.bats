#!/usr/bin/env bats
# Tests for plugins/test-watcher. They run a copy of test-watcher.sh (so the
# watcher processes of each test can be told apart by their path) with a
# PATH of only test stubs and symlinks to the system tools it needs. The
# herdr stub serves `pane read` from a file and logs every call; `sleep` is a
# stub that naps briefly, so watchers poll fast. No real herdr, agent, or
# test runner is used, and teardown fails a test that leaves a watcher.
#
# Each test runs in its own subshell, so changing RUN_ENV in one test is
# meant to stay local to it.
# shellcheck disable=SC2030,SC2031

setup() {
  load helpers/common
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  PLUGIN_DIR="$REPO_ROOT/plugins/test-watcher"
  STUBS_DIR="$BATS_TEST_DIRNAME/stubs"
  STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  TEST_BIN="$BATS_TEST_TMPDIR/bin"
  SYSBIN="$BATS_TEST_TMPDIR/sysbin"
  STATE_DIR="$BATS_TEST_TMPDIR/state"
  CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  : >"$STUB_LOG"
  mkdir -p "$TEST_BIN" "$SYSBIN" "$STATE_DIR" "$CONFIG_DIR"
  local tool
  for tool in sh awk sed jq cat tr mkdir mv rm ps cksum nohup grep; do
    ln -s "$(command -v "$tool")" "$SYSBIN/$tool"
  done
  ln -s "$STUBS_DIR/date" "$TEST_BIN/date"
  printf '#!/bin/sh\nexec %s 0.05\n' "$(command -v sleep)" >"$TEST_BIN/sleep"
  chmod +x "$TEST_BIN/sleep"
  PLUGIN_COPY="$BATS_TEST_TMPDIR/plugin"
  mkdir -p "$PLUGIN_COPY"
  cp "$PLUGIN_DIR/test-watcher.sh" "$PLUGIN_COPY/"
  PANE_OUTPUT="$BATS_TEST_TMPDIR/pane-output.txt"
  printf '$ npm test\n' >"$PANE_OUTPUT"
  PANE_GONE="$BATS_TEST_TMPDIR/pane-gone"
  PANE_JSON="$BATS_TEST_TMPDIR/pane.json"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1","label":null,"cwd":"/work/app"},"type":"pane_info"}}' >"$PANE_JSON"
  CONTEXT='{"focused_pane_id":"w1:p1","focused_pane_cwd":"/work/app"}'
  RUN_ENV=("STUB_HERDR_PANE_READ=$PANE_OUTPUT" "STUB_HERDR_PANE_READ_FAIL=$PANE_GONE"
    "STUB_HERDR_PANE_GET=$PANE_JSON" "STUB_DATE_HM=14:32")
}

# Print the pids of watcher processes of this test's plugin copy. The path
# reaches awk through the environment, so awk's own command line, which ps
# also lists, does not contain it.
watcher_pids() {
  ps -A -o pid= -o args= | WATCHER="$PLUGIN_COPY/test-watcher.sh run" awk 'index($0, ENVIRON["WATCHER"]) { print $1 }'
}

# Wait up to about five seconds for $1 to succeed.
eventually() {
  local tries=0
  until "$@"; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || return 1
    sleep 0.05
  done
}

logged() { grep -qxF -- "$1" "$STUB_LOG"; }
no_watchers() { [ -z "$(watcher_pids)" ]; }
watcher_count() { watcher_pids | awk 'END { print NR }'; }

teardown() {
  # A test must not leave a watcher behind.
  if ! eventually no_watchers; then
    echo "watchers left running: $(watcher_pids)"
    # shellcheck disable=SC2046
    kill $(watcher_pids) 2>/dev/null
    return 1
  fi
}

# Run test-watcher.sh MODE like herdr does, for the pane in $CONTEXT.
run_watcher() {
  run env -i \
    PATH="$TEST_BIN:$SYSBIN" \
    HERDR_BIN_PATH="$STUBS_DIR/herdr" \
    HERDR_PLUGIN_STATE_DIR="$STATE_DIR" \
    HERDR_PLUGIN_CONFIG_DIR="$CONFIG_DIR" \
    HERDR_PLUGIN_CONTEXT_JSON="$CONTEXT" \
    HERDR_PLUGIN_EVENT_JSON="${EVENT_JSON:-}" \
    STUB_LOG="$STUB_LOG" \
    ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
    "$SYSBIN/sh" "$PLUGIN_COPY/test-watcher.sh" "$@"
}

# Classify stdin with the default patterns (or the patterns file in
# $CONFIG_DIR).
classify() {
  run_watcher classify
}

token() {
  printf 'herdr pane report-metadata %s --source oh-my-herdr.test-watcher %s' "$1" "$2"
}

# --- What counts as failing or passing ------------------------------------

@test "failures of common test runners and builds are detected" {
  local sample
  for sample in \
    $'FAIL src/sum.test.js\n  sum > adds\nTests:       1 failed, 2 passed, 3 total' \
    $' FAIL  src/sum.test.ts > adds\n Test Files  1 failed (1)\n      Tests  1 failed | 1 passed (2)' \
    $'FAILED tests/test_x.py::test_add - assert 1 == 2\n===== 1 failed, 2 passed in 0.12s =====' \
    $'--- FAIL: TestAdd (0.00s)\nFAIL\nFAIL\texample.com/m\t0.002s' \
    $'test tests::add ... FAILED\n\ntest result: FAILED. 1 passed; 1 failed; 0 ignored' \
    $'  2 passing (8ms)\n  1 failing' \
    $'3 examples, 1 failure' \
    $'Error: Cannot find module \'left-pad\'' \
    $'src/a.ts(1,7): error TS2322: Type \'string\' is not assignable' \
    $'error[E0308]: mismatched types'; do
    classify <<<"$sample"
    echo "$sample => $output"
    [ "$status" -eq 0 ]
    [ "$output" = fail ]
  done
}

@test "passing runs of common test runners are detected" {
  local sample
  for sample in \
    $'PASS src/sum.test.js\nTests:       3 passed, 3 total' \
    $' Test Files  1 passed (1)\n      Tests  2 passed (2)' \
    $'===== 3 passed in 0.05s =====' \
    $'ok  \texample.com/m\t0.002s' \
    $'test result: ok. 3 passed; 0 failed; 0 ignored' \
    $'  3 passing (5ms)' \
    $'3 examples, 0 failures'; do
    classify <<<"$sample"
    echo "$sample => $output"
    [ "$status" -eq 0 ]
    [ "$output" = pass ]
  done
}

@test "zero failures and ordinary words are not failures" {
  classify <<<"Tests: 3 passed, 0 failed"
  [ "$output" = pass ]
  local sample
  for sample in "0 failures" "the word failed appears here" "error handling works" "no errors found"; do
    classify <<<"$sample"
    echo "$sample => $output"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "the last result on screen decides" {
  classify <<<$'Tests: 1 failed, 2 passed\n$ npm test\nTests: 3 passed, 3 total'
  [ "$output" = pass ]
  classify <<<$'Tests: 3 passed, 3 total\n$ npm test\nTests: 1 failed, 2 passed'
  [ "$output" = fail ]
}

@test "a patterns file replaces the default failures or passes and adds lines to ignore" {
  cat >"$CONFIG_DIR/patterns" <<'EOF'
# My build prints BROKEN or GREEN.
fail ^BROKEN
pass ^GREEN

ignore ^Error: expected in this project
EOF
  classify <<<"BROKEN: lint"
  [ "$output" = fail ]
  classify <<<"GREEN after 3s"
  [ "$output" = pass ]
  classify <<<"Tests: 1 failed, 2 passed"
  [ -z "$output" ]
  printf 'fail ^Error:\n' >"$CONFIG_DIR/patterns"
  printf 'ignore ^Error: expected\n' >>"$CONFIG_DIR/patterns"
  classify <<<$'Error: expected noise'
  [ -z "$output" ]
  classify <<<$'Error: real one'
  [ "$output" = fail ]
}

@test "a patterns file that is not valid is reported" {
  printf 'fail (\n' >"$CONFIG_DIR/patterns"
  classify <<<"anything"
  echo "$output"
  [ "$status" -ne 0 ]
  assert_output_contains "could not apply the test patterns"
}

# --- Watching -------------------------------------------------------------

@test "the toggle action starts a watcher for the focused pane, and again stops it" {
  run_watcher toggle
  echo "$output"
  [ "$status" -eq 0 ]
  eventually logged "$(token w1:p1 '--token tests=watching')"
  [ "$(watcher_count)" = 1 ]
  [ -f "$STATE_DIR/watchers/w1_p1.pid" ]
  run_watcher toggle
  [ "$status" -eq 0 ]
  eventually no_watchers
  [ ! -e "$STATE_DIR/watchers/w1_p1.pid" ]
  assert_logged "$(token w1:p1 '--clear-token tests')"
}

@test "watching a pane that is already watched starts no second watcher" {
  run_watcher watch
  eventually logged "$(token w1:p1 '--token tests=watching')"
  run_watcher watch
  [ "$status" -eq 0 ]
  sleep 0.3
  [ "$(watcher_count)" = 1 ]
  run_watcher stop
  eventually no_watchers
}

@test "two watchers started at once for one pane leave one" {
  env -i PATH="$TEST_BIN:$SYSBIN" HERDR_BIN_PATH="$STUBS_DIR/herdr" HERDR_PLUGIN_STATE_DIR="$STATE_DIR" \
    STUB_LOG="$STUB_LOG" "${RUN_ENV[@]}" "$SYSBIN/sh" "$PLUGIN_COPY/test-watcher.sh" run w1:p1 >/dev/null 2>&1 &
  env -i PATH="$TEST_BIN:$SYSBIN" HERDR_BIN_PATH="$STUBS_DIR/herdr" HERDR_PLUGIN_STATE_DIR="$STATE_DIR" \
    STUB_LOG="$STUB_LOG" "${RUN_ENV[@]}" "$SYSBIN/sh" "$PLUGIN_COPY/test-watcher.sh" run w1:p1 >/dev/null 2>&1 &
  eventually logged "$(token w1:p1 '--token tests=watching')"
  sleep 0.5
  [ "$(watcher_count)" = 1 ]
  run_watcher stop
  eventually no_watchers
}

@test "at most eight panes are watched; the ninth is refused with a notification" {
  local n
  for n in 1 2 3 4 5 6 7 8; do
    CONTEXT="{\"focused_pane_id\":\"w1:p$n\"}"
    run_watcher watch
    [ "$status" -eq 0 ]
    eventually logged "$(token "w1:p$n" '--token tests=watching')"
  done
  CONTEXT='{"focused_pane_id":"w1:p9"}'
  run_watcher watch
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr notification show Test watcher --body Already watching 8 panes; stop one before watching another."
  sleep 0.3
  [ "$(watcher_count)" = 8 ]
  refute_logged "$(token w1:p9 '--token tests=watching')"
  run_watcher startup
  eventually no_watchers
}

@test "a failing run marks the pane and notifies once; a passing run then marks it passing" {
  run_watcher watch
  eventually logged "$(token w1:p1 '--token tests=watching')"
  printf '$ npm test\nTests:       1 failed, 2 passed, 3 total\n$ ' >"$PANE_OUTPUT"
  eventually logged "$(token w1:p1 '--token tests=✗ failing since 14:32')"
  assert_logged "herdr notification show Tests failing --body app (pane w1:p1)"
  printf '$ npm test\nTests:       3 passed, 3 total\n$ ' >"$PANE_OUTPUT"
  eventually logged "$(token w1:p1 '--token tests=✓ passing')"
  [ "$(grep -c '^herdr notification show' "$STUB_LOG")" = 1 ]
  run_watcher stop
  eventually no_watchers
}

@test "a failure already on screen when watching starts is marked without a notification" {
  printf 'Tests:       1 failed, 2 passed, 3 total\n' >"$PANE_OUTPUT"
  run_watcher watch
  eventually logged "$(token w1:p1 '--token tests=✗ failing since 14:32')"
  sleep 0.3
  refute_logged "herdr notification show Tests failing --body app (pane w1:p1)"
  run_watcher stop
  eventually no_watchers
}

@test "stopping a watcher in the middle of a report leaves no token behind" {
  # The stub's sleep naps briefly, so the slow report goes through the real one.
  RUN_ENV+=("STUB_HERDR_REPORT_DELAY=0.5" "STUB_REAL_SLEEP=$(command -v sleep)")
  run_watcher watch
  eventually grep -qxF "pane report-metadata w1:p1 --source oh-my-herdr.test-watcher --token tests=watching" "$STUB_LOG.reports-done"
  printf 'Tests:       1 failed, 2 passed, 3 total\n' >"$PANE_OUTPUT"
  # Stop while the failing token is being written.
  eventually logged "$(token w1:p1 '--token tests=✗ failing since 14:32')"
  eventually test -e "$STUB_LOG.report-busy"
  run_watcher stop
  [ "$status" -eq 0 ]
  eventually no_watchers
  sleep 0.7
  cat "$STUB_LOG.reports-done"
  # The last word on the token is the stop's clear.
  [ "$(grep '^pane report-metadata w1:p1 ' "$STUB_LOG.reports-done" | tail -n 1)" = \
    "pane report-metadata w1:p1 --source oh-my-herdr.test-watcher --clear-token tests" ]
}

nap_count() { awk 'END { print NR }' "$BATS_TEST_TMPDIR/naps"; }
naps_at_least() { [ "$(nap_count)" -ge "$1" ]; }

@test "after read errors, a successful read brings the poll interval back down" {
  # This sleep records each nap and, once the watcher has backed off to 8
  # seconds or more, lets the pane be read again.
  cat >"$TEST_BIN/sleep" <<EOF
#!/bin/sh
printf '%s\\n' "\$1" >>"$BATS_TEST_TMPDIR/naps"
if [ "\$1" -ge 8 ] 2>/dev/null; then
  rm -f "$PANE_GONE"
fi
exec $(command -v sleep) 0.05
EOF
  run_watcher watch
  eventually logged "$(token w1:p1 '--token tests=watching')"
  eventually test -s "$BATS_TEST_TMPDIR/naps"
  printf 'internal' >"$PANE_GONE"
  eventually grep -qE '^([89]|[1-9][0-9]+)$' "$BATS_TEST_TMPDIR/naps"
  # Wait for a few naps after the recovery, then stop.
  local before
  before="$(nap_count)"
  eventually naps_at_least "$((before + 3))"
  run_watcher stop
  eventually no_watchers
  cat "$BATS_TEST_TMPDIR/naps"
  # The nap right after the first long one is back to the fast interval (2),
  # plus at most the one step an unchanged read adds.
  local next
  next="$(awk 'found { print; exit } $1 >= 8 { found = 1 }' "$BATS_TEST_TMPDIR/naps")"
  [ -n "$next" ] && [ "$next" -le 3 ]
}

@test "a watcher stops by itself when its pane is gone" {
  run_watcher watch
  eventually logged "$(token w1:p1 '--token tests=watching')"
  printf 'pane_not_found' >"$PANE_GONE"
  eventually no_watchers
  [ ! -e "$STATE_DIR/watchers/w1_p1.pid" ]
  # A gone pane has no token to clear.
  refute_logged "$(token w1:p1 '--clear-token tests')"
}

@test "a watcher stops at once when the herdr server is gone" {
  run_watcher watch
  eventually logged "$(token w1:p1 '--token tests=watching')"
  printf 'server_not_running' >"$PANE_GONE"
  eventually no_watchers
  [ ! -e "$STATE_DIR/watchers/w1_p1.pid" ]
  # It left because the server is gone, not after retrying.
  run cat "$STATE_DIR/watchers/w1_p1.log"
  echo "$output"
  refute_output_contains "times in a row"
}

@test "pane exit and pane close events stop that pane's watcher" {
  local n
  for n in 1 2; do
    CONTEXT="{\"focused_pane_id\":\"w1:p$n\"}"
    run_watcher watch
    eventually logged "$(token "w1:p$n" '--token tests=watching')"
  done
  EVENT_JSON='{"event":"pane_exited","data":{"type":"pane_exited","pane_id":"w1:p1","workspace_id":"w1"}}'
  run_watcher event
  [ "$status" -eq 0 ]
  eventually test ! -e "$STATE_DIR/watchers/w1_p1.pid"
  [ -f "$STATE_DIR/watchers/w1_p2.pid" ]
  EVENT_JSON='{"event":"pane_closed","data":{"type":"pane_closed","pane_id":"w1:p2","workspace_id":"w1"}}'
  run_watcher event
  [ "$status" -eq 0 ]
  eventually no_watchers
  [ ! -e "$STATE_DIR/watchers/w1_p2.pid" ]
}

@test "startup stops watchers from before and removes stale pid files" {
  local dead
  sh -c 'exit 0' &
  dead=$!
  wait "$dead"
  mkdir -p "$STATE_DIR/watchers"
  printf '%s\n' "$dead" >"$STATE_DIR/watchers/w1_p5.pid"
  run_watcher watch
  eventually logged "$(token w1:p1 '--token tests=watching')"
  run_watcher startup
  [ "$status" -eq 0 ]
  eventually no_watchers
  local left=("$STATE_DIR"/watchers/*.pid)
  [ ! -e "${left[0]}" ]
}

@test "a pid file pointing at an unrelated process never gets that process killed" {
  sleep 30 &
  local unrelated=$!
  mkdir -p "$STATE_DIR/watchers"
  printf '%s\n' "$unrelated" >"$STATE_DIR/watchers/w1_p1.pid"
  run_watcher toggle
  eventually logged "$(token w1:p1 '--token tests=watching')"
  kill -0 "$unrelated"
  [ "$(cat "$STATE_DIR/watchers/w1_p1.pid")" != "$unrelated" ]
  run_watcher stop
  eventually no_watchers
  kill -0 "$unrelated"
  kill "$unrelated"
}

# --- Sending the failure to an agent --------------------------------------

@test "the send action opens agent-handoff's fix-failing-tests prompt for the pane and sends nothing itself" {
  run_watcher send
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr plugin pane open --plugin oh-my-herdr.agent-handoff --entrypoint prompts --env OMH_HANDOFF_PANE=w1:p1 --env OMH_HANDOFF_CWD=/work/app --env OMH_HANDOFF_PROMPT=fix-failing-tests.md"
  refute_logged "herdr agent prompt"
}

@test "when agent-handoff's popup cannot open, the send action says so" {
  RUN_ENV+=("STUB_HERDR_PANE_OPEN_FAIL=1")
  run_watcher send
  [ "$status" -eq 0 ]
  assert_logged_prefix "herdr notification show Test watcher --body Could not open the agent-handoff prompt popup"
}

# --- Manifest, module, and safety -----------------------------------------

@test "the manifest declares jq, the startup cleanup, the exit events, and the actions" {
  run grep -q '^# Requires: jq on PATH' "$PLUGIN_DIR/herdr-plugin.toml"
  [ "$status" -eq 0 ]
  run python3 -I -c '
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    manifest = tomllib.load(handle)
assert manifest["id"] == "oh-my-herdr.test-watcher", manifest["id"]
assert manifest["min_herdr_version"] == "0.9.0"
(startup,) = manifest["startup"]
assert startup["command"] == ["sh", "test-watcher.sh", "startup"], startup
events = sorted(event["on"] for event in manifest["events"])
assert events == ["pane.closed", "pane.exited"], events
assert all(event["command"] == ["sh", "test-watcher.sh", "event"] for event in manifest["events"])
actions = {action["id"]: action for action in manifest["actions"]}
assert sorted(actions) == ["send", "stop", "toggle", "watch"], actions
for action_id, action in actions.items():
    assert action["command"] == ["sh", "test-watcher.sh", action_id], action
    assert action["contexts"] == ["pane"], action
assert "panes" not in manifest and "build" not in manifest
' "$PLUGIN_DIR/herdr-plugin.toml"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the module binds prefix+ctrl+w to toggle watching and prefix+ctrl+e to send the failure" {
  run grep -q '^# Requires: jq on PATH' "$REPO_ROOT/config/modules/test-watcher.toml"
  [ "$status" -eq 0 ]
  run python3 -I -c '
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    commands = {c["key"]: c for c in tomllib.load(handle)["keys"]["command"]}
assert sorted(commands) == ["prefix+ctrl+e", "prefix+ctrl+w"], commands
assert commands["prefix+ctrl+w"]["command"] == "oh-my-herdr.test-watcher.toggle", commands
assert commands["prefix+ctrl+e"]["command"] == "oh-my-herdr.test-watcher.send", commands
assert all(c["type"] == "plugin_action" and c["description"] for c in commands.values()), commands
' "$REPO_ROOT/config/modules/test-watcher.toml"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the plugin never starts, prompts, or types into agents and makes no network calls" {
  run grep -nE 'agent start|agent prompt|send-keys|send-text|--dangerously|skip-permissions|--yolo|bypass|curl|wget' "$PLUGIN_DIR/test-watcher.sh"
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
  printf '%s' "$output" | jq -e '.result.plugins[] | select(.plugin_id == "oh-my-herdr.test-watcher" and .enabled)'
}
