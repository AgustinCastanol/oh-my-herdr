#!/usr/bin/env bats
# Tests for plugins/agent-inbox. The script runs with a PATH of only test
# stubs and symlinks to the system tools it needs. The herdr stub
# (HERDR_BIN_PATH) serves `agent list`, `workspace list`, and `tab list` from
# files and logs every call to $STUB_LOG; the date stub serves a fixed clock.
# No real agent is started, prompted, or focused.
#
# Each test runs in its own subshell, so changing RUN_ENV in one test is
# meant to stay local to it.
# shellcheck disable=SC2030,SC2031

setup() {
  load helpers/common
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  PLUGIN_DIR="$REPO_ROOT/plugins/agent-inbox"
  STUBS_DIR="$BATS_TEST_DIRNAME/stubs"
  STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  TEST_BIN="$BATS_TEST_TMPDIR/bin"
  SYSBIN="$BATS_TEST_TMPDIR/sysbin"
  STATE_DIR="$BATS_TEST_TMPDIR/state"
  : >"$STUB_LOG"
  mkdir -p "$TEST_BIN" "$SYSBIN" "$STATE_DIR"
  ln -s "$STUBS_DIR/date" "$TEST_BIN/date"
  local tool
  for tool in sh awk sed jq cat tr mkdir mv rm sleep ln readlink; do
    ln -s "$(command -v "$tool")" "$SYSBIN/$tool"
  done
  AGENTS="$BATS_TEST_TMPDIR/agents.json"
  set_agents
  WORKSPACES="$BATS_TEST_TMPDIR/workspaces.json"
  cat >"$WORKSPACES" <<'EOF'
{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[
{"workspace_id":"w1","label":"work","focused":true},
{"workspace_id":"w2","label":"other","focused":false}]}}
EOF
  TABS="$BATS_TEST_TMPDIR/tabs.json"
  cat >"$TABS" <<'EOF'
{"id":"cli:tab:list","result":{"type":"tab_list","tabs":[
{"tab_id":"w1:t1","label":"1","workspace_id":"w1"},
{"tab_id":"w2:t1","label":"api","workspace_id":"w2"}]}}
EOF
  RUN_ENV=("STUB_HERDR_AGENTS=$AGENTS" "STUB_HERDR_WORKSPACES=$WORKSPACES" "STUB_HERDR_TABS=$TABS")
}

# Write the `agent list` output: one agent per argument, given as
# "PANE STATUS AGENT CWD" (the tab is the pane's workspace plus ":t1").
set_agents() {
  local entry pane status agent cwd json=''
  for entry in "$@"; do
    read -r pane status agent cwd <<<"$entry"
    json="$json${json:+,}$(jq -cn --arg pane "$pane" --arg status "$status" --arg agent "$agent" --arg cwd "$cwd" \
      '{pane_id: $pane, agent: $agent, agent_status: $status, cwd: $cwd, foreground_cwd: $cwd,
        workspace_id: ($pane | split(":")[0]), tab_id: (($pane | split(":")[0]) + ":t1"), focused: false}')"
  done
  printf '{"id":"cli:agent:list","result":{"agents":[%s],"type":"agent_list"}}\n' "$json" >"$AGENTS"
}

# Run the plugin like herdr does. Usage: run_plugin MODE [EVENT [EVENT_JSON]]
# The clock is STUB_DATE_EPOCH/STUB_DATE_HM from RUN_ENV, else 1000 / 12:00.
run_plugin() {
  run env -i \
    PATH="$TEST_BIN:$SYSBIN" \
    HERDR_BIN_PATH="$STUBS_DIR/herdr" \
    HERDR_PLUGIN_STATE_DIR="$STATE_DIR" \
    HERDR_PLUGIN_EVENT="${2:-}" \
    HERDR_PLUGIN_EVENT_JSON="${3:-}" \
    STUB_LOG="$STUB_LOG" \
    ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
    "$SYSBIN/sh" "$PLUGIN_DIR/agent-inbox.sh" "$1"
}

# The event herdr sends when pane $1 changes to agent status $2.
status_event() {
  printf '{"event":"pane_agent_status_changed","data":{"type":"pane_agent_status_changed","pane_id":"%s","workspace_id":"%s","agent_status":"%s","agent":"claude"}}' \
    "$1" "${1%%:*}" "$2"
}

# Print what the plugin recorded for pane $1: "PANE STATE EPOCH HH:MM".
record_of() {
  local file
  for file in "$STATE_DIR"/waiting/*; do
    [ -f "$file" ] || continue
    awk -v pane="$1" '$1 == pane' "$file"
  done
}

# Record pane $1 as waiting in state $2 since epoch $3 (HH:MM $4) the way an
# earlier event would have. Agents seeded earlier in the test stay listed, so
# their records stay too.
SEEDED=()
seed_record() {
  SEEDED+=("$1 $2 claude /work/app")
  set_agents "${SEEDED[@]}"
  # The clock applies to this seeding run only: restore the caller's RUN_ENV.
  local saved_env=("${RUN_ENV[@]}")
  RUN_ENV+=("STUB_DATE_EPOCH=$3" "STUB_DATE_HM=$4")
  run_plugin event pane.agent_status_changed "$(status_event "$1" "$2")"
  [ "$status" -eq 0 ]
  RUN_ENV=("${saved_env[@]}")
  : >"$STUB_LOG"
}

# --- Tracking who waits ---------------------------------------------------

@test "a blocked agent is recorded with the time and gets a waiting token" {
  set_agents "w1:p2 blocked claude /work/app" "w1:p3 working codex /work/app"
  RUN_ENV+=("STUB_DATE_EPOCH=5000" "STUB_DATE_HM=14:32")
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 blocked)"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(record_of w1:p2)" = "w1:p2 blocked 5000 14:32" ]
  [ -z "$(record_of w1:p3)" ]
  assert_logged "herdr pane report-metadata w1:p2 --source oh-my-herdr.agent-inbox --token waiting=blocked since 14:32"
  refute_logged "herdr pane report-metadata w1:p3"
}

@test "an agent that finished while you were elsewhere is recorded as done" {
  set_agents "w2:p1 done claude /work/api"
  RUN_ENV+=("STUB_DATE_EPOCH=5000" "STUB_DATE_HM=14:05")
  run_plugin event pane.agent_status_changed "$(status_event w2:p1 "done")"
  [ "$status" -eq 0 ]
  [ "$(record_of w2:p1)" = "w2:p1 done 5000 14:05" ]
  assert_logged "herdr pane report-metadata w2:p1 --source oh-my-herdr.agent-inbox --token waiting=done since 14:05"
}

@test "an agent that stays waiting keeps the time it started waiting" {
  seed_record w1:p2 blocked 5000 14:32
  RUN_ENV+=("STUB_DATE_EPOCH=6000" "STUB_DATE_HM=14:49")
  run_plugin event pane.focused '{"event":"pane_focused","data":{"type":"pane_focused","pane_id":"w1:p1","workspace_id":"w1"}}'
  [ "$status" -eq 0 ]
  [ "$(record_of w1:p2)" = "w1:p2 blocked 5000 14:32" ]
  refute_logged "herdr pane report-metadata"
}

@test "a blocked agent that finishes unseen starts a new wait as done" {
  seed_record w1:p2 blocked 5000 14:32
  set_agents "w1:p2 done claude /work/app"
  RUN_ENV+=("STUB_DATE_EPOCH=6000" "STUB_DATE_HM=14:49")
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 "done")"
  [ "$status" -eq 0 ]
  [ "$(record_of w1:p2)" = "w1:p2 done 6000 14:49" ]
  assert_logged "herdr pane report-metadata w1:p2 --source oh-my-herdr.agent-inbox --token waiting=done since 14:49"
  refute_logged "herdr pane report-metadata w1:p2 --source oh-my-herdr.agent-inbox --clear-token waiting"
}

@test "a waiting agent that works again is cleared" {
  seed_record w1:p2 blocked 5000 14:32
  set_agents "w1:p2 working claude /work/app"
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 working)"
  [ "$status" -eq 0 ]
  [ -z "$(record_of w1:p2)" ]
  assert_logged "herdr pane report-metadata w1:p2 --source oh-my-herdr.agent-inbox --clear-token waiting"
}

@test "a done agent you looked at (herdr turns it idle on focus) is cleared" {
  seed_record w2:p1 "done" 5000 14:05
  set_agents "w2:p1 idle claude /work/api"
  run_plugin event pane.focused '{"event":"pane_focused","data":{"type":"pane_focused","pane_id":"w2:p1","workspace_id":"w2"}}'
  [ "$status" -eq 0 ]
  [ -z "$(record_of w2:p1)" ]
  assert_logged "herdr pane report-metadata w2:p1 --source oh-my-herdr.agent-inbox --clear-token waiting"
}

@test "an agent that quits (status unknown) is cleared" {
  seed_record w1:p2 blocked 5000 14:32
  set_agents "w1:p2 unknown claude /work/app"
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 unknown)"
  [ "$status" -eq 0 ]
  [ -z "$(record_of w1:p2)" ]
  assert_logged "herdr pane report-metadata w1:p2 --source oh-my-herdr.agent-inbox --clear-token waiting"
}

@test "an exited pane is forgotten" {
  seed_record w1:p2 blocked 5000 14:32
  set_agents
  run_plugin event pane.exited '{"event":"pane_exited","data":{"type":"pane_exited","pane_id":"w1:p2","workspace_id":"w1"}}'
  [ "$status" -eq 0 ]
  [ -z "$(record_of w1:p2)" ]
}

@test "when the agent list cannot be read, nothing changes" {
  seed_record w1:p2 blocked 5000 14:32
  set_agents
  RUN_ENV+=("STUB_HERDR_AGENT_LIST_FAIL=1")
  run_plugin event pane.exited '{"event":"pane_exited","data":{"type":"pane_exited","pane_id":"w1:p2","workspace_id":"w1"}}'
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(record_of w1:p2)" = "w1:p2 blocked 5000 14:32" ]
  refute_logged "herdr pane report-metadata"
  assert_output_contains "could not list agents"
}

@test "a pane id with unexpected characters is ignored" {
  set_agents "../evil blocked claude /work/app" "w1:p2/x done claude /work/app"
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 blocked)"
  [ "$status" -eq 0 ]
  [ ! -e "$STATE_DIR/evil" ]
  local leftovers=("$STATE_DIR"/waiting/*)
  [ ! -e "${leftovers[0]}" ]
  refute_logged "herdr pane report-metadata"
}

@test "startup forgets records from an earlier server and records who waits now" {
  seed_record w1:p2 blocked 5000 14:32
  seed_record w9:p9 "done" 5000 14:32
  set_agents "w1:p2 blocked claude /work/app" "w2:p1 done claude /work/api" "w1:p3 working codex /work/app"
  RUN_ENV+=("STUB_DATE_EPOCH=9000" "STUB_DATE_HM=16:00")
  run_plugin sync
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(record_of w1:p2)" = "w1:p2 blocked 9000 16:00" ]
  [ "$(record_of w2:p1)" = "w2:p1 done 9000 16:00" ]
  [ -z "$(record_of w9:p9)" ]
  [ -z "$(record_of w1:p3)" ]
  assert_logged "herdr pane report-metadata w1:p2 --source oh-my-herdr.agent-inbox --token waiting=blocked since 16:00"
  assert_logged "herdr pane report-metadata w2:p1 --source oh-my-herdr.agent-inbox --token waiting=done since 16:00"
}

@test "startup drops earlier records even when the agent list cannot be read" {
  seed_record w1:p2 blocked 5000 14:32
  seed_record w2:p1 "done" 5000 14:32
  RUN_ENV+=("STUB_HERDR_AGENT_LIST_FAIL=1")
  run_plugin sync
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$(record_of w1:p2)" ]
  [ -z "$(record_of w2:p1)" ]
  assert_output_contains "could not list agents"
  assert_logged "herdr pane report-metadata w1:p2 --source oh-my-herdr.agent-inbox --clear-token waiting"
  assert_logged "herdr pane report-metadata w2:p1 --source oh-my-herdr.agent-inbox --clear-token waiting"
}

@test "an agent entry without a pane id is skipped" {
  printf '%s\n' '{"result":{"agents":[{"agent":"claude","agent_status":"blocked"},{"pane_id":"w1:p2","agent":"claude","agent_status":"blocked"}],"type":"agent_list"}}' >"$AGENTS"
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 blocked)"
  [ "$status" -eq 0 ]
  [ "$(record_of null)" = "" ]
  [ -n "$(record_of w1:p2)" ]
  refute_logged "herdr pane report-metadata null"
}

# --- Serialized updates ---------------------------------------------------

# Run the plugin in MODE $1 without bats' `run`, so it can go to the
# background. Extra environment comes from the remaining arguments.
plugin_in_background() {
  local mode=$1
  shift
  env -i PATH="$TEST_BIN:$SYSBIN" HERDR_BIN_PATH="$STUBS_DIR/herdr" \
    HERDR_PLUGIN_STATE_DIR="$STATE_DIR" STUB_LOG="$STUB_LOG" \
    ${RUN_ENV[@]+"${RUN_ENV[@]}"} "$@" \
    "$SYSBIN/sh" "$PLUGIN_DIR/agent-inbox.sh" "$mode" >"$BATS_TEST_TMPDIR/background.out" 2>&1
}

# --- Serialized updates with a kernel lock (flock or lockf) ---------------

# Put the machine's flock or lockf on the plugin's PATH, or skip the test.
use_kernel_lock() {
  local tool
  for tool in flock lockf; do
    if command -v "$tool" >/dev/null 2>&1; then
      ln -s "$(command -v "$tool")" "$SYSBIN/$tool"
      KERNEL_LOCK_TOOL=$tool
      return 0
    fi
  done
  skip "neither flock nor lockf is installed"
}

# Hold the kernel lock from a background process until release_kernel_lock;
# kill -9 on HOLDER simulates an update that died.
hold_kernel_lock() {
  case "$KERNEL_LOCK_TOOL" in
    flock) flock "$STATE_DIR/inbox.lock" sleep 30 & ;;
    lockf) lockf -k "$STATE_DIR/inbox.lock" sleep 30 & ;;
  esac
  HOLDER=$!
  eventually_locked
}

kernel_lock_busy() {
  case "$KERNEL_LOCK_TOOL" in
    flock) ! flock -n "$STATE_DIR/inbox.lock" true ;;
    lockf) ! lockf -k -s -t 0 "$STATE_DIR/inbox.lock" true ;;
  esac
}

eventually_locked() {
  local tries=0
  until kernel_lock_busy; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || return 1
    sleep 0.05
  done
}

release_kernel_lock() {
  # Note the holder's child first: after a kill -9 it would be orphaned.
  local children
  children="$(pgrep -P "$HOLDER" || true)"
  kill "${1:--TERM}" "$HOLDER" 2>/dev/null || true
  # shellcheck disable=SC2086
  [ -z "$children" ] || kill $children 2>/dev/null || true
  wait "$HOLDER" 2>/dev/null || true
}

@test "with a kernel lock, an update that arrives while another holds the lock is applied when that one finishes" {
  use_kernel_lock
  set_agents "w1:p2 blocked claude /work/app"
  plugin_in_background event STUB_HERDR_AGENT_LIST_DELAY=1 &
  local first=$! tries=0
  until [ -e "$STUB_LOG.list-read" ] || [ "$tries" -ge 100 ]; do
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -e "$STUB_LOG.list-read" ]
  set_agents "w1:p2 working claude /work/app"
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 working)"
  echo "$output"
  [ "$status" -eq 0 ]
  kill -0 "$first"
  wait "$first"
  cat "$BATS_TEST_TMPDIR/background.out"
  [ -z "$(record_of w1:p2)" ]
  [ "$(grep -c '^herdr agent list' "$STUB_LOG")" = 2 ]
  [ "$(grep '^herdr pane report-metadata w1:p2 ' "$STUB_LOG" | tail -n 1)" = \
    "herdr pane report-metadata w1:p2 --source oh-my-herdr.agent-inbox --clear-token waiting" ]
  [ -f "$STATE_DIR/inbox.lock" ]
  [ ! -L "$STATE_DIR/lock" ]
  [ ! -e "$STATE_DIR/rerun" ]
}

@test "with a kernel lock, an update returns at once while another holds it, leaving its request" {
  use_kernel_lock
  hold_kernel_lock
  set_agents "w1:p2 blocked claude /work/app"
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 blocked)"
  echo "$output"
  release_kernel_lock
  [ "$status" -eq 0 ]
  [ -e "$STATE_DIR/rerun" ]
  refute_logged "herdr agent list"
  [ -z "$(record_of w1:p2)" ]
}

@test "with a kernel lock, an update that died leaves nothing to take over" {
  use_kernel_lock
  hold_kernel_lock
  release_kernel_lock -9
  set_agents "w1:p2 blocked claude /work/app"
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 blocked)"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -n "$(record_of w1:p2)" ]
  refute_output_contains "took over"
  [ ! -L "$STATE_DIR/lock" ]
}

@test "with a kernel lock, requests that keep arriving stop after 5 rounds and stay pending" {
  use_kernel_lock
  set_agents "w1:p2 blocked claude /work/app"
  RUN_ENV+=("STUB_HERDR_AGENT_LIST_TOUCH=$STATE_DIR/rerun")
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 blocked)"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^herdr agent list' "$STUB_LOG")" = 5 ]
  assert_output_contains "still asked to update after 5 rounds; leaving the request for the next event"
  [ -e "$STATE_DIR/rerun" ]
}

# Put a stub flock on the plugin's PATH. $1 is how it behaves: "no-E" runs
# the command but rejects -E like old or BusyBox flock; "busy" never runs it;
# "late" runs it, then leaves a new request (once) and exits 1.
stub_flock() {
  cat >"$TEST_BIN/flock" <<EOF
#!/bin/sh
mode=$1
for arg in "\$@"; do
  if [ "\$arg" = -E ]; then
    echo "flock: invalid option -- 'E'" >&2
    exit 64
  fi
done
[ "\$mode" != busy ] || exit 1
[ "\$1" != -n ] || shift
shift
"\$@"
if [ "\$mode" = late ] && [ ! -e "$BATS_TEST_TMPDIR/late-done" ]; then
  : >"$BATS_TEST_TMPDIR/late-done"
  : >"$STATE_DIR/rerun"
  exit 1
fi
EOF
  chmod +x "$TEST_BIN/flock"
}

@test "with a flock that has no -E option, updates still run" {
  stub_flock no-E
  set_agents "w1:p2 blocked claude /work/app"
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 blocked)"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -n "$(record_of w1:p2)" ]
  [ ! -e "$STATE_DIR/rerun" ]
}

@test "with a flock that finds the lock taken, the request is left for the holder" {
  stub_flock busy
  set_agents "w1:p2 blocked claude /work/app"
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 blocked)"
  [ "$status" -eq 0 ]
  [ -e "$STATE_DIR/rerun" ]
  refute_logged "herdr agent list"
}

@test "a request left as the holder finishes is served, whatever status the lock tool returns" {
  stub_flock late
  set_agents "w1:p2 blocked claude /work/app"
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 blocked)"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^herdr agent list' "$STUB_LOG")" = 2 ]
  [ ! -e "$STATE_DIR/rerun" ]
}

stalled_list_is_cut_off() {
  set_agents "w1:p2 blocked claude /work/app"
  RUN_ENV+=("OMH_INBOX_LIST_TIMEOUT=1" "STUB_HERDR_AGENT_LIST_DELAY=31")
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 blocked)"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "herdr agent list did not answer within 1 seconds"
  [ -z "$(record_of w1:p2)" ]
  eventually_no_stalled_list
  # The lock was released: the next update runs.
  RUN_ENV=("${RUN_ENV[@]:0:3}")
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 blocked)"
  [ -n "$(record_of w1:p2)" ]
}

eventually_no_stalled_list() {
  local tries=0
  while pgrep -f "sleep 31" >/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 60 ] || return 1
    sleep 0.05
  done
}

@test "a stalled agent list is cut off with timeout so it cannot hold the lock" {
  command -v timeout >/dev/null 2>&1 || skip "timeout is not installed"
  ln -s "$(command -v timeout)" "$SYSBIN/timeout"
  stalled_list_is_cut_off
}

@test "a stalled agent list is cut off by a watchdog when timeout is not installed" {
  stalled_list_is_cut_off
}

# --- Serialized updates without flock or lockf (symlink lock) -------------

# The fallback lock: a symlink whose target is "PID EPOCH" of its owner.
lock_owner() { readlink "$STATE_DIR/lock"; }

@test "an update that arrives while another holds the lock is applied when that one finishes" {
  set_agents "w1:p2 blocked claude /work/app"
  # The first update reads "blocked" and then stalls; meanwhile the agent works
  # again and a second update runs.
  plugin_in_background event STUB_HERDR_AGENT_LIST_DELAY=1 &
  local first=$! tries=0
  until [ -e "$STUB_LOG.list-read" ] || [ "$tries" -ge 100 ]; do
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -e "$STUB_LOG.list-read" ]
  set_agents "w1:p2 working claude /work/app"
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 working)"
  echo "$output"
  [ "$status" -eq 0 ]
  # The second update left its request and returned without waiting.
  kill -0 "$first"
  wait "$first"
  cat "$BATS_TEST_TMPDIR/background.out"
  [ -z "$(record_of w1:p2)" ]
  # The first update ran again for the request and read the list twice.
  [ "$(grep -c '^herdr agent list' "$STUB_LOG")" = 2 ]
  [ "$(grep '^herdr pane report-metadata w1:p2 ' "$STUB_LOG" | tail -n 1)" = \
    "herdr pane report-metadata w1:p2 --source oh-my-herdr.agent-inbox --clear-token waiting" ]
  [ ! -L "$STATE_DIR/lock" ]
  [ ! -e "$STATE_DIR/rerun" ]
}

@test "while a live update holds the lock, another leaves a request and returns at once" {
  ln -s "$$ 1000" "$STATE_DIR/lock"
  set_agents "w1:p2 blocked claude /work/app"
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 blocked)"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -e "$STATE_DIR/rerun" ]
  refute_logged "herdr agent list"
  [ -z "$(record_of w1:p2)" ]
  [ "$(lock_owner)" = "$$ 1000" ]
}

@test "a startup request left for the lock holder still starts the inbox afresh" {
  seed_record w1:p2 blocked 5000 14:32
  # A live holder that took the lock just now (the clock is 9000).
  ln -s "$$ 9000" "$STATE_DIR/lock"
  RUN_ENV+=("STUB_DATE_EPOCH=9000" "STUB_DATE_HM=16:00")
  run_plugin sync
  [ "$status" -eq 0 ]
  [ "$(record_of w1:p2)" = "w1:p2 blocked 5000 14:32" ]
  # The holder finishes; the next update takes the lock and serves the request.
  rm "$STATE_DIR/lock"
  run_plugin event pane.focused '{"event":"pane_focused","data":{"type":"pane_focused","pane_id":"w1:p1","workspace_id":"w1"}}'
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(record_of w1:p2)" = "w1:p2 blocked 9000 16:00" ]
  [ ! -e "$STATE_DIR/rerun-fresh" ]
}

@test "requests that keep arriving stop after a bounded number of rounds, with a log line" {
  set_agents "w1:p2 blocked claude /work/app"
  RUN_ENV+=("STUB_HERDR_AGENT_LIST_TOUCH=$STATE_DIR/rerun")
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 blocked)"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^herdr agent list' "$STUB_LOG")" = 5 ]
  assert_output_contains "still asked to update after 5 rounds; leaving the request for the next event"
  [ -e "$STATE_DIR/rerun" ]
  [ ! -L "$STATE_DIR/lock" ]
}

@test "a lock left by an update that died is taken over" {
  local dead
  sh -c 'exit 0' &
  dead=$!
  wait "$dead"
  ln -s "$dead 1000" "$STATE_DIR/lock"
  set_agents "w1:p2 blocked claude /work/app"
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 blocked)"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -n "$(record_of w1:p2)" ]
  [ ! -L "$STATE_DIR/lock" ]
  local graves=("$STATE_DIR"/lock.*)
  [ ! -e "${graves[0]}" ] && [ ! -L "${graves[0]}" ]
}

@test "a lock held for more than 30 seconds is taken over" {
  # A live process (this test) that took the lock long ago (the clock is 1000).
  ln -s "$$ 900" "$STATE_DIR/lock"
  set_agents "w1:p2 blocked claude /work/app"
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 blocked)"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -n "$(record_of w1:p2)" ]
}

@test "a waiter that found a left-over lock never removes the live lock that replaced it" {
  ln -s "$$ 900" "$STATE_DIR/lock"
  # Right after the waiter reads the left-over lock, another update replaces
  # it with a live one: the moment a check-then-remove would go wrong.
  cat >"$TEST_BIN/readlink" <<EOF
#!/bin/sh
"$SYSBIN/readlink" "\$@"
status=\$?
if [ ! -e "$BATS_TEST_TMPDIR/swapped" ]; then
  : >"$BATS_TEST_TMPDIR/swapped"
  "$SYSBIN/rm" "$STATE_DIR/lock"
  "$SYSBIN/ln" -s "$$ 1000" "$STATE_DIR/lock"
fi
exit \$status
EOF
  chmod +x "$TEST_BIN/readlink"
  set_agents "w1:p2 blocked claude /work/app"
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 blocked)"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -e "$BATS_TEST_TMPDIR/swapped" ]
  [ "$(lock_owner)" = "$$ 1000" ]
  local graves=("$STATE_DIR"/lock.*)
  [ ! -e "${graves[0]}" ] && [ ! -L "${graves[0]}" ]
  refute_logged "herdr agent list"
  [ -e "$STATE_DIR/rerun" ]
}

@test "waiters contending for a left-over lock all finish and leave nothing behind" {
  local dead pids=() pid
  sh -c 'exit 0' &
  dead=$!
  wait "$dead"
  ln -s "$dead 1000" "$STATE_DIR/lock"
  set_agents "w1:p2 blocked claude /work/app"
  for pid in 1 2 3 4; do
    plugin_in_background event &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid"
  done
  [ -n "$(record_of w1:p2)" ]
  [ ! -L "$STATE_DIR/lock" ]
  local graves=("$STATE_DIR"/lock.*)
  [ ! -e "${graves[0]}" ] && [ ! -L "${graves[0]}" ]
  [ ! -e "$STATE_DIR/rerun" ]
}

@test "a lock directory left by an earlier version is replaced" {
  mkdir -p "$STATE_DIR/lock"
  printf '%s 1000\n' "$$" >"$STATE_DIR/lock/owner"
  set_agents "w1:p2 blocked claude /work/app"
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 blocked)"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -n "$(record_of w1:p2)" ]
  [ ! -e "$STATE_DIR/lock" ] && [ ! -L "$STATE_DIR/lock" ]
}

# --- The popup ------------------------------------------------------------

# Waiting agents for the popup tests, recorded at different times, plus one
# that works again and one waiting without a record (it waited before the
# plugin saw it).
seed_inbox() {
  seed_record w2:p1 "done" 1000 10:00
  seed_record w1:p2 "done" 2500 10:25
  seed_record w1:p3 blocked 3000 10:33
  seed_record w2:p2 blocked 1600 10:10
  seed_record w1:p4 blocked 1200 10:03
  set_agents "w2:p1 done claude /work/api" "w1:p2 done codex /work/app" \
    "w1:p3 blocked claude /work/app" "w2:p2 blocked opencode /srv/api" \
    "w1:p4 working claude /work/app" "w1:p5 blocked claude /work/web"
  RUN_ENV+=("STUB_DATE_EPOCH=4000" "STUB_DATE_HM=11:06")
}

@test "the popup lists blocked agents first, then done ones, each longest wait first" {
  seed_inbox
  run_plugin popup <<<""
  echo "$output"
  [ "$status" -eq 0 ]
  local menu
  menu="$(printf '%s\n' "$output" | grep -E '^ +[0-9]+\) ')"
  [ "$menu" = "$(printf '%s\n' \
    '  1) w2:p2  blocked  opencode  other/api  api  waiting 40m' \
    '  2) w1:p3  blocked  claude  work/1  app  waiting 16m' \
    '  3) w1:p5  blocked  claude  work/1  web  waiting <1m' \
    '  4) w2:p1  done  claude  other/api  api  waiting 50m' \
    '  5) w1:p2  done  codex  work/1  app  waiting 25m')" ]
  refute_logged "herdr agent focus"
}

@test "waits of an hour or more show hours and minutes" {
  seed_record w1:p3 blocked 1000 10:00
  set_agents "w1:p3 blocked claude /work/app"
  RUN_ENV+=("STUB_DATE_EPOCH=8500")
  run_plugin popup <<<""
  echo "$output"
  assert_output_contains "  1) w1:p3  blocked  claude  work/1  app  waiting 2h05m"
}

@test "picking an agent from the menu focuses it" {
  seed_inbox
  run_plugin popup <<<"2"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr agent focus w1:p3"
  [ "$(grep -c '^herdr agent focus' "$STUB_LOG")" = 1 ]
}

@test "with fzf, the picked agent is focused" {
  seed_inbox
  ln -s "$STUBS_DIR/fzf" "$TEST_BIN/fzf"
  RUN_ENV+=("STUB_FZF_PICK=w2:p1  done  claude  other/api  api  waiting 50m")
  run_plugin popup </dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged_prefix "fzf "
  assert_logged "herdr agent focus w2:p1"
}

@test "cancelling the menu focuses nothing" {
  seed_inbox
  run_plugin popup <<<""
  [ "$status" -eq 0 ]
  refute_logged "herdr agent focus"
}

@test "with no agent waiting, it says so and waits for a key" {
  set_agents "w1:p2 working claude /work/app" "w1:p3 idle codex /work/app"
  run_plugin popup <<<""
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "No agents are waiting for you."
  assert_output_contains "Press Enter to close."
  refute_logged "herdr agent focus"
}

@test "an agent that cannot be focused is reported" {
  seed_inbox
  RUN_ENV+=("STUB_HERDR_FOCUS_FAIL=1")
  run_plugin popup <<<"1"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "agent target w2:p2 not found"
}

@test "an agent list herdr cannot give is reported instead of an empty inbox" {
  RUN_ENV+=("STUB_HERDR_AGENT_LIST_FAIL=1")
  run_plugin popup <<<""
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "Could not read the agent list: no herdr server is running at stub.sock"
  refute_output_contains "No agents are waiting"
}

@test "an agent list the popup cannot read is reported instead of an empty inbox" {
  printf '%s\n' '{"result":{"agents":[{"pane_id":"w1:p2","agent":"claude","agent_status":"blocked","cwd":42}],"type":"agent_list"}}' >"$AGENTS"
  run_plugin popup <<<""
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "Could not read the agent list: "
  refute_output_contains "No agents are waiting"
}

@test "the popup skips agent entries without a pane id" {
  printf '%s\n' '{"result":{"agents":[{"agent":"codex","agent_status":"blocked","cwd":"/x"},{"pane_id":"w1:p2","agent":"claude","agent_status":"blocked","cwd":"/work/app","workspace_id":"w1","tab_id":"w1:t1"}],"type":"agent_list"}}' >"$AGENTS"
  run_plugin popup <<<""
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "  1) w1:p2  blocked  claude  work/1  app  waiting <1m"
  refute_output_contains "  2) "
  refute_output_contains "codex"
}

@test "the open action opens the inbox popup" {
  run_plugin open
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr plugin pane open --plugin oh-my-herdr.agent-inbox --entrypoint inbox"
}

# --- Manifest, module, and safety -----------------------------------------

@test "the manifest declares jq, a startup sync, the events, a popup, and an open action" {
  run grep -q '^# Requires: jq on PATH' "$PLUGIN_DIR/herdr-plugin.toml"
  [ "$status" -eq 0 ]
  run python3 -I -c '
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    manifest = tomllib.load(handle)
assert manifest["id"] == "oh-my-herdr.agent-inbox", manifest["id"]
assert manifest["min_herdr_version"] == "0.9.0"
(startup,) = manifest["startup"]
assert startup["command"] == ["sh", "agent-inbox.sh", "sync"], startup
events = sorted(event["on"] for event in manifest["events"])
assert events == ["pane.agent_status_changed", "pane.closed", "pane.exited", "pane.focused"], events
assert all(event["command"] == ["sh", "agent-inbox.sh", "event"] for event in manifest["events"])
(pane,) = manifest["panes"]
assert pane["id"] == "inbox" and pane["placement"] == "popup", pane
assert pane["command"] == ["sh", "agent-inbox.sh", "popup"], pane
(action,) = manifest["actions"]
assert action["id"] == "open" and action["command"] == ["sh", "agent-inbox.sh", "open"], action
assert "build" not in manifest
' "$PLUGIN_DIR/herdr-plugin.toml"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the module binds prefix+i to the open action" {
  run grep -q '^# Requires: jq on PATH' "$REPO_ROOT/config/modules/agent-inbox.toml"
  [ "$status" -eq 0 ]
  run python3 -I -c '
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    (command,) = tomllib.load(handle)["keys"]["command"]
assert command["key"] == "prefix+i", command["key"]
assert command["type"] == "plugin_action", command["type"]
assert command["command"] == "oh-my-herdr.agent-inbox.open", command["command"]
assert command["description"], command
' "$REPO_ROOT/config/modules/agent-inbox.toml"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the plugin never starts, prompts, or types into agents and makes no network calls" {
  run grep -nE 'agent start|agent prompt|send-keys|--dangerously|skip-permissions|--yolo|bypass|curl|wget' "$PLUGIN_DIR/agent-inbox.sh"
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
  printf '%s' "$output" | jq -e '.result.plugins[] | select(.plugin_id == "oh-my-herdr.agent-inbox" and .enabled)'
}

# A flock with no -E option that really locks (perl's flock), like BusyBox
# flock or util-linux flock before 2.25.
stub_locking_flock() {
  local perl
  perl="$(command -v perl)" || skip "perl is not on PATH"
  {
    printf '#!%s\n' "$perl"
    cat <<'EOF'
use Fcntl qw(:flock);
my @a = @ARGV;
for (@a) { if ($_ eq '-E') { print STDERR "flock: invalid option -- 'E'\n"; exit 64; } }
my $nb = 0;
if ($a[0] eq '-n') { $nb = 1; shift @a; }
my $file = shift @a;
open(my $fh, '>>', $file) or exit 66;
flock($fh, LOCK_EX | ($nb ? LOCK_NB : 0)) or exit 1;
my $pid = fork();
if ($pid == 0) { exec @a or exit 127; }
waitpid($pid, 0);
exit($? >> 8);
EOF
  } >"$TEST_BIN/flock"
  chmod +x "$TEST_BIN/flock"
}

@test "with a locking flock that has no -E, an update arriving while another holds the lock is applied when that one finishes" {
  stub_locking_flock
  set_agents "w1:p2 blocked claude /work/app"
  plugin_in_background event STUB_HERDR_AGENT_LIST_DELAY=1 &
  local first=$! tries=0
  until [ -e "$STUB_LOG.list-read" ] || [ "$tries" -ge 100 ]; do
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -e "$STUB_LOG.list-read" ]
  set_agents "w1:p2 working claude /work/app"
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 working)"
  echo "$output"
  [ "$status" -eq 0 ]
  kill -0 "$first"
  wait "$first"
  [ -z "$(record_of w1:p2)" ]
  [ "$(grep -c '^herdr agent list' "$STUB_LOG")" = 2 ]
  [ ! -e "$STATE_DIR/rerun" ]
  [ -z "$(find "$STATE_DIR" -name '.served.*')" ]
}

@test "a fast agent list leaves no watchdog sleep behind" {
  set_agents "w1:p2 blocked claude /work/app"
  RUN_ENV+=("OMH_INBOX_LIST_TIMEOUT=47")
  run_plugin event pane.agent_status_changed "$(status_event w1:p2 blocked)"
  [ "$status" -eq 0 ]
  [ -n "$(record_of w1:p2)" ]
  sleep 0.2
  [ -z "$(pgrep -f "sleep 47")" ]
}
