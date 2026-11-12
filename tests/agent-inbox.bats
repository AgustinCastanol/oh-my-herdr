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
  for tool in sh awk sed jq cat tr mkdir mv rm; do
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
  RUN_ENV+=("STUB_DATE_EPOCH=$3" "STUB_DATE_HM=$4")
  run_plugin event pane.agent_status_changed "$(status_event "$1" "$2")"
  [ "$status" -eq 0 ]
  RUN_ENV=("${RUN_ENV[@]:0:3}")
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
