#!/usr/bin/env bats
# Tests for plugins/agent-race. They run a copy of agent-race.sh against a
# throwaway git repository, with a PATH of test stubs, symlinks to the system
# tools it needs, and empty commands named like agents. git is real (the
# worktrees are real); herdr is the stub, which logs every call. No agent is
# started or prompted, and teardown fails a test that leaves a delivery
# process running.
#
# Each test runs in its own subshell, so changing RUN_ENV in one test is
# meant to stay local to it.
# shellcheck disable=SC2030,SC2031

setup() {
  load helpers/common
  # git prints resolved paths (/private/var on macOS), so the test paths
  # compared with its output are resolved too.
  BATS_TEST_TMPDIR="$(cd -P "$BATS_TEST_TMPDIR" && pwd)"
  command -v jq >/dev/null 2>&1 || skip "jq is not on PATH"
  command -v git >/dev/null 2>&1 || skip "git is not on PATH"
  PLUGIN_DIR="$REPO_ROOT/plugins/agent-race"
  STUBS_DIR="$BATS_TEST_DIRNAME/stubs"
  STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  TEST_BIN="$BATS_TEST_TMPDIR/bin"
  SYSBIN="$BATS_TEST_TMPDIR/sysbin"
  STATE_DIR="$BATS_TEST_TMPDIR/state"
  HOME_DIR="$BATS_TEST_TMPDIR/home"
  : >"$STUB_LOG"
  mkdir -p "$TEST_BIN" "$SYSBIN" "$STATE_DIR" "$HOME_DIR"
  local tool
  for tool in sh awk sed jq cat tr mkdir mv rm grep git wc head ps nohup sort date; do
    ln -s "$(command -v "$tool")" "$SYSBIN/$tool"
  done
  # Deliveries detach with setsid, or else perl, when the system has them.
  for tool in setsid perl; do
    if command -v "$tool" >/dev/null 2>&1; then
      ln -s "$(command -v "$tool")" "$SYSBIN/$tool"
    fi
  done
  # Commands named like three of the agent kinds herdr can start.
  for tool in claude codex gemini; do
    printf '#!/bin/sh\nexit 0\n' >"$TEST_BIN/$tool"
    chmod +x "$TEST_BIN/$tool"
  done
  PLUGIN_COPY="$BATS_TEST_TMPDIR/plugin"
  mkdir -p "$PLUGIN_COPY"
  cp "$PLUGIN_DIR/agent-race.sh" "$PLUGIN_COPY/"
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q -b main "$REPO"
  printf 'hello\n' >"$REPO/a.txt"
  git -C "$REPO" add a.txt
  git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q -m base
  BASE="$(git -C "$REPO" rev-parse HEAD)"
  WORKTREES="$HOME_DIR/.herdr/worktrees/repo"
  RUN_ENV=()
}

delivery_pids() {
  ps -A -o pid= -o args= | ME="$PLUGIN_COPY/agent-race.sh deliver" awk 'index($0, ENVIRON["ME"]) { print $1 }'
}
deliveries_done() { [ -z "$(delivery_pids)" ]; }

eventually() {
  local tries=0
  until "$@"; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || return 1
    sleep 0.05
  done
}

teardown() {
  if ! eventually deliveries_done; then
    echo "delivery processes left running: $(delivery_pids)"
    # shellcheck disable=SC2046
    kill $(delivery_pids) 2>/dev/null
    return 1
  fi
}

# Run agent-race.sh MODE like herdr does after an action on pane w1:p1,
# whose directory is $RACE_CWD (default: the test repository).
run_race() {
  run env -i \
    PATH="$TEST_BIN:$SYSBIN" \
    HOME="$HOME_DIR" \
    HERDR_BIN_PATH="$STUBS_DIR/herdr" \
    HERDR_PLUGIN_STATE_DIR="$STATE_DIR" \
    OMH_RACE_PANE=w1:p1 \
    OMH_RACE_CWD="${RACE_CWD:-$REPO}" \
    OMH_AGENT_HANDOFF="$REPO_ROOT/plugins/agent-handoff/agent-handoff.sh" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" \
    STUB_LOG="$STUB_LOG" \
    ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
    "$SYSBIN/sh" "$PLUGIN_COPY/agent-race.sh" "$@"
}

# Start a race for task $1 with agents $2 (menu numbers, default "1 2":
# claude and codex), confirm it, and wait until every delivery is done.
start_race() {
  run_race start <<<"$1"$'\n'"${2:-1 2}"$'\ny\n'
  echo "$output"
  [ "$status" -eq 0 ] || return 1
  eventually deliveries_done
}

worktrees() { git -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p'; }
has_branch() { git -C "$REPO" rev-parse --verify --quiet "refs/heads/$1" >/dev/null; }
# A negated command does not fail a bats test unless it comes last, so the
# negations are functions.
no_branch() { ! has_branch "$1"; }
not_listed() { ! worktrees | grep -qF "$1"; }
race_status() { cat "$STATE_DIR/races/$1/$2.status"; }

# --- Starting -------------------------------------------------------------

@test "outside a git repository it says so and does nothing" {
  RACE_CWD="$BATS_TEST_TMPDIR"
  run_race start <<<""
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "Agent race needs a git repository"
  refute_logged "herdr worktree"
  refute_logged "herdr agent"
}

@test "with fewer than two agents on PATH it says so" {
  rm "$TEST_BIN/codex" "$TEST_BIN/gemini"
  run_race start <<<"Fix the login bug"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "needs at least 2 agents whose command is on PATH"
  refute_logged "herdr worktree"
}

@test "the agents herdr can start whose command is on PATH are offered" {
  run_race start <<<$'Fix the login bug\n'
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "  1) claude"
  assert_output_contains "  2) codex"
  assert_output_contains "  3) gemini"
  refute_output_contains ") pi"
  refute_output_contains ") opencode"
  [ "$(worktrees)" = "$REPO" ]
}

@test "a kind whose command has another name is offered when that command is on PATH" {
  # herdr starts the kind kiro as kiro-cli.
  printf '#!/bin/sh\nexit 0\n' >"$TEST_BIN/kiro-cli"
  chmod +x "$TEST_BIN/kiro-cli"
  run_race start <<<$'Fix the login bug\n'
  echo "$output"
  assert_output_contains "  4) kiro"
  rm "$TEST_BIN/kiro-cli"
  printf '#!/bin/sh\nexit 0\n' >"$TEST_BIN/kiro"
  chmod +x "$TEST_BIN/kiro"
  run_race start <<<$'Fix the login bug\n'
  echo "$output"
  refute_output_contains ") kiro"
}

@test "fewer than two or more than four agents are refused" {
  run_race start <<<$'Fix the login bug\n1'
  echo "$output"
  assert_output_contains "Pick 2 to 4 agents"
  printf '#!/bin/sh\nexit 0\n' >"$TEST_BIN/pi"
  printf '#!/bin/sh\nexit 0\n' >"$TEST_BIN/opencode"
  chmod +x "$TEST_BIN/pi" "$TEST_BIN/opencode"
  run_race start <<<$'Fix the login bug\n1 2 3 4 5'
  echo "$output"
  assert_output_contains "Pick 2 to 4 agents"
  [ "$(worktrees)" = "$REPO" ]
  refute_logged "herdr agent start race"
  refute_logged "herdr agent prompt"
}

@test "the summary shows task, base, branches, and worktrees; declining creates and sends nothing" {
  run_race start <<<$'Fix the login bug\n1 2\nn'
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "Task: Fix the login bug"
  assert_output_contains "Base: ${BASE:0:7} (main)"
  assert_output_contains "claude  race/fix-the-login-bug-claude  $WORKTREES/race-fix-the-login-bug-claude"
  assert_output_contains "codex  race/fix-the-login-bug-codex  $WORKTREES/race-fix-the-login-bug-codex"
  assert_output_contains "Nothing was started."
  [ "$(worktrees)" = "$REPO" ]
  no_branch race/fix-the-login-bug-claude
  refute_logged "herdr worktree"
  refute_logged "herdr agent start race"
  refute_logged "herdr agent prompt"
  [ ! -e "$STATE_DIR/races/fix-the-login-bug" ]
}

@test "confirming creates a worktree per agent from the base and sends each the task once it is ready" {
  start_race "Fix the login bug"
  local kind wt
  for kind in claude codex; do
    wt="$WORKTREES/race-fix-the-login-bug-$kind"
    worktrees | grep -qxF "$wt"
    [ "$(git -C "$wt" rev-parse HEAD)" = "$BASE" ]
    [ "$(git -C "$wt" symbolic-ref --short HEAD)" = "race/fix-the-login-bug-$kind" ]
    assert_logged "herdr worktree open --cwd $REPO --path $wt --label race-fix-the-login-bug-$kind --no-focus"
    assert_logged "herdr agent start race-fix-the-login-bug-$kind --kind $kind --pane race-fix-the-login-bug-$kind:p1 --timeout 60000"
    assert_logged "herdr agent prompt race-fix-the-login-bug-$kind Fix the login bug"
    [ "$(race_status fix-the-login-bug "$kind")" = "task sent" ]
  done
  [ "$(awk 'END { print NR }' "$STATE_DIR/races/fix-the-login-bug/agents")" = 2 ]
  [ "$(cat "$STATE_DIR/races/fix-the-login-bug/task")" = "Fix the login bug" ]
}

@test "no agent start or agent prompt carries an approval-bypass flag or extra agent arguments" {
  start_race "Fix the login bug" "1 2 3"
  run grep -E '^herdr agent (start|prompt) race' "$STUB_LOG"
  echo "$output"
  [ "${#lines[@]}" -eq 6 ]
  run grep -E -- '--dangerously-skip-permissions|--yolo|--auto-approve|--skip-permissions-unsafe|--permission-mode|bypass' "$STUB_LOG"
  [ "$status" -eq 1 ]
  run grep -E '^herdr agent start .* -- ' "$STUB_LOG"
  [ "$status" -eq 1 ]
}

@test "an agent whose worktree cannot be opened is reported and rolled back; the others still race" {
  RUN_ENV+=("STUB_HERDR_OPEN_FAIL=codex")
  start_race "Fix the login bug"
  assert_output_contains "codex: could not open the worktree"
  assert_logged "herdr agent prompt race-fix-the-login-bug-claude Fix the login bug"
  refute_logged "herdr agent start race-fix-the-login-bug-codex"
  not_listed race-fix-the-login-bug-codex
  no_branch race/fix-the-login-bug-codex
  [ "$(awk 'END { print NR }' "$STATE_DIR/races/fix-the-login-bug/agents")" = 1 ]
}

@test "an agent waiting at a startup prompt gets the task once it is ready" {
  RUN_ENV+=("STUB_HERDR_START_NOT_READY=claude")
  start_race "Fix the login bug"
  assert_logged "herdr agent wait race-fix-the-login-bug-claude --until idle --timeout 600000"
  assert_logged "herdr agent prompt race-fix-the-login-bug-claude Fix the login bug"
  [ "$(race_status fix-the-login-bug claude)" = "task sent" ]
}

@test "an agent that never becomes ready, or cannot start, does not get the task" {
  RUN_ENV+=("STUB_HERDR_START_NOT_READY=claude" "STUB_HERDR_WAIT_FAIL=1" "STUB_HERDR_START_FAIL=codex")
  start_race "Fix the login bug" "1 2 3"
  refute_logged "herdr agent prompt race-fix-the-login-bug-claude"
  refute_logged "herdr agent prompt race-fix-the-login-bug-codex"
  assert_logged "herdr agent prompt race-fix-the-login-bug-gemini Fix the login bug"
  race_status fix-the-login-bug claude | grep -q "task not sent"
  race_status fix-the-login-bug codex | grep -q "could not start"
}

@test "a saved prompt can be the task, and {{cwd}} becomes each agent's worktree" {
  mkdir -p "$BATS_TEST_TMPDIR/config/oh-my-herdr/prompts"
  printf '# Check the repo\n\nList the files in {{cwd}}.\n' >"$BATS_TEST_TMPDIR/config/oh-my-herdr/prompts/check.md"
  run_race start <<<$'\n1\n1 2\ny'
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "  1) Check the repo  (check.md, yours)"
  # Prompts that attach pane output are not offered.
  refute_output_contains "Explain this error"
  eventually deliveries_done
  [ "$(cat "$STUB_LOG.prompt-text.race-check-the-repo-claude")" = \
    "$(printf '# Check the repo\n\nList the files in %s.' "$WORKTREES/race-check-the-repo-claude")" ]
  [ "$(cat "$STUB_LOG.prompt-text.race-check-the-repo-codex")" = \
    "$(printf '# Check the repo\n\nList the files in %s.' "$WORKTREES/race-check-the-repo-codex")" ]
}

@test "a long task still gives agent names herdr accepts, and they all start" {
  start_race "Add a greeting line to a.txt and keep the tests green" "1 2 3"
  run grep -E '^herdr agent start ' "$STUB_LOG"
  echo "$output"
  local line name
  for line in "${lines[@]}"; do
    name="$(printf '%s\n' "$line" | awk '{ print $4 }')"
    [ "$name" = --help ] && continue
    printf '%s\n' "$name" | grep -Eqx '[a-z][a-z0-9_-]{0,31}'
  done
  [ "$(grep -c '^herdr agent prompt ' "$STUB_LOG")" = 3 ]
}

@test "a race name that is taken gets a number" {
  start_race "Fix the login bug"
  start_race "Fix the login bug"
  [ -d "$STATE_DIR/races/fix-the-login-bug-2" ]
  has_branch race/fix-the-login-bug-2-claude
}

@test "at most three races run at a time" {
  mkdir -p "$STATE_DIR/races/one" "$STATE_DIR/races/two" "$STATE_DIR/races/three"
  run_race start <<<"Fix the login bug"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "There are already 3 races"
  refute_logged "herdr worktree"
}

# --- Comparing ------------------------------------------------------------

@test "compare shows each agent's state, delivery, and changes against the base" {
  start_race "Fix the login bug"
  printf 'changed\n' >>"$WORKTREES/race-fix-the-login-bug-claude/a.txt"
  printf 'new\n' >"$WORKTREES/race-fix-the-login-bug-claude/b.txt"
  run_race compare <<<""
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "claude  race/fix-the-login-bug-claude"
  assert_output_contains "agent: working; task sent"
  assert_output_contains " 1 file changed, 1 insertion(+)"
  assert_output_contains "1 untracked file"
  assert_output_contains "codex  race/fix-the-login-bug-codex"
  assert_output_contains "no changes"
  refute_logged "herdr pane split"
}

@test "compare opens one agent's full diff in a new pane only when asked" {
  start_race "Fix the login bug"
  run_race compare <<<"1"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr pane split w1:p1 --direction down"
  assert_logged "herdr pane run w1:p9 git -C '$WORKTREES/race-fix-the-login-bug-claude' -c core.fsmonitor=false -c core.hooksPath=/dev/null diff --no-ext-diff --no-textconv '$BASE'"
}

@test "compare points to reviewr when it is installed, without running it" {
  start_race "Fix the login bug"
  RUN_ENV+=("STUB_HERDR_PLUGINS=persiyanov.reviewr")
  run_race compare <<<""
  echo "$output"
  assert_output_contains "persiyanov.reviewr is installed"
  refute_logged "herdr plugin action"
  refute_logged "herdr plugin pane open"
}

# --- Cleaning up ----------------------------------------------------------

@test "cleanup removes nothing unless the race name is typed" {
  start_race "Fix the login bug"
  run_race cleanup <<<""
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "Nothing was removed."
  [ "$(worktrees | awk 'END { print NR }')" = 3 ]
  refute_logged "herdr workspace close"
}

@test "cleanup removes clean worktrees, closes their workspaces, deletes merged race branches, and forgets the race" {
  start_race "Fix the login bug"
  run_race cleanup <<<"fix-the-login-bug"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr workspace close ws-race-fix-the-login-bug-claude"
  assert_logged "herdr workspace close ws-race-fix-the-login-bug-codex"
  [ "$(worktrees)" = "$REPO" ]
  no_branch race/fix-the-login-bug-claude
  no_branch race/fix-the-login-bug-codex
  has_branch main
  [ ! -e "$STATE_DIR/races/fix-the-login-bug" ]
}

@test "a worktree with changes is kept unless discard is typed" {
  start_race "Fix the login bug"
  printf 'changed\n' >>"$WORKTREES/race-fix-the-login-bug-claude/a.txt"
  run_race cleanup <<<$'fix-the-login-bug\n'
  echo "$output"
  assert_output_contains "race-fix-the-login-bug-claude  [changes]"
  worktrees | grep -qxF "$WORKTREES/race-fix-the-login-bug-claude"
  not_listed race-fix-the-login-bug-codex
  [ "$(awk 'END { print NR }' "$STATE_DIR/races/fix-the-login-bug/agents")" = 1 ]
  run_race cleanup <<<$'fix-the-login-bug\ndiscard'
  echo "$output"
  [ "$(worktrees)" = "$REPO" ]
  [ ! -e "$STATE_DIR/races/fix-the-login-bug" ]
}

@test "race branches with commits that are not merged are kept unless delete is typed" {
  start_race "Fix the login bug"
  local wt="$WORKTREES/race-fix-the-login-bug-claude"
  printf 'changed\n' >>"$wt/a.txt"
  git -C "$wt" -c user.name=t -c user.email=t@example.com commit -q -am "agent work"
  run_race cleanup <<<$'fix-the-login-bug\n'
  echo "$output"
  assert_output_contains "race/fix-the-login-bug-claude"
  [ "$(worktrees)" = "$REPO" ]
  has_branch race/fix-the-login-bug-claude
  no_branch race/fix-the-login-bug-codex
  has_branch main
}

@test "unmerged race branches are deleted after delete is typed, and the base branch never is" {
  start_race "Fix the login bug"
  local wt="$WORKTREES/race-fix-the-login-bug-claude"
  printf 'changed\n' >>"$wt/a.txt"
  git -C "$wt" -c user.name=t -c user.email=t@example.com commit -q -am "agent work"
  run_race cleanup <<<$'fix-the-login-bug\ndelete'
  echo "$output"
  no_branch race/fix-the-login-bug-claude
  has_branch main
  [ "$(git -C "$REPO" rev-parse main)" = "$BASE" ]
}

@test "compare refuses a race record whose base is not a commit id, and runs nothing from it" {
  start_race "Fix the login bug"
  local marker="$BATS_TEST_TMPDIR/evaluated"
  sed -i.bak "s|^base=.*|base=HEAD; touch $marker|" "$STATE_DIR/races/fix-the-login-bug/race"
  run_race compare <<<"1"
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "has no valid base commit"
  refute_logged "herdr pane split"
  refute_logged "herdr pane run"
  [ ! -e "$marker" ]
}

@test "a worktree with only ignored files is kept unless discard is typed" {
  start_race "Fix the login bug"
  printf '.env.local\n' >>"$REPO/.git/info/exclude"
  printf 'SECRET=1\n' >"$WORKTREES/race-fix-the-login-bug-claude/.env.local"
  run_race cleanup <<<$'fix-the-login-bug\n'
  echo "$output"
  assert_output_contains "race-fix-the-login-bug-claude  [ignored files: 1]"
  worktrees | grep -qxF "$WORKTREES/race-fix-the-login-bug-claude"
  [ -f "$WORKTREES/race-fix-the-login-bug-claude/.env.local" ]
  not_listed race-fix-the-login-bug-codex
  run_race cleanup <<<$'fix-the-login-bug\ndiscard'
  echo "$output"
  [ "$(worktrees)" = "$REPO" ]
}

# Each appended line is a separate tampered record, written one by one.
# shellcheck disable=SC2129
@test "cleanup leaves alone any recorded worktree that is not where the race put it" {
  start_race "Fix the login bug"
  local user_wt="$BATS_TEST_TMPDIR/user-worktree" agents="$STATE_DIR/races/fix-the-login-bug/agents"
  git -C "$REPO" worktree add -q -b user/work "$user_wt"
  # Another worktree of the user's, the same through "..", and a symlink
  # standing where a race worktree would be.
  ln -s "$user_wt" "$WORKTREES/race-fix-the-login-bug-gemini"
  printf 'pi\trace/fix-the-login-bug-pi\t%s\tws-race-fix-the-login-bug-pi\t-\trace-fix-the-login-bug-pi\n' "$user_wt" >>"$agents"
  printf 'amp\trace/fix-the-login-bug-amp\t%s\tws-race-fix-the-login-bug-amp\t-\trace-fix-the-login-bug-amp\n' \
    "$WORKTREES/race-fix-the-login-bug-claude/../../../../user-worktree" >>"$agents"
  printf 'gemini\trace/fix-the-login-bug-gemini\t%s\tws-race-fix-the-login-bug-gemini\t-\trace-fix-the-login-bug-gemini\n' \
    "$WORKTREES/race-fix-the-login-bug-gemini" >>"$agents"
  run_race cleanup <<<$'fix-the-login-bug\ndiscard\ndelete'
  echo "$output"
  assert_output_contains "pi: the race record does not point at this race's worktree"
  assert_output_contains "amp: the race record does not point at this race's worktree"
  assert_output_contains "gemini: the race record does not point at this race's worktree"
  worktrees | grep -qxF "$user_wt"
  [ -d "$user_wt" ]
  has_branch user/work
  refute_logged "herdr workspace close ws-race-fix-the-login-bug-pi"
  refute_logged "herdr workspace close ws-race-fix-the-login-bug-amp"
  refute_logged "herdr workspace close ws-race-fix-the-login-bug-gemini"
  not_listed race-fix-the-login-bug-claude
}

@test "cleanup closes a workspace only when its id and label are the race's" {
  start_race "Fix the login bug"
  local agents="$STATE_DIR/races/fix-the-login-bug/agents"
  # The claude record now names the user's workspace w1.
  sed -i.bak 's/\tws-race-fix-the-login-bug-claude\t/\tw1\t/' "$agents"
  run_race cleanup <<<"fix-the-login-bug"
  echo "$output"
  refute_logged "herdr workspace close w1"
  assert_logged "herdr workspace close ws-race-fix-the-login-bug-codex"
}

# Each appended line is a separate tampered record, written one by one.
# shellcheck disable=SC2129
@test "cleanup never deletes a branch outside this race, even when the race record names it" {
  start_race "Fix the login bug"
  git -C "$REPO" branch feature/user-work
  git -C "$REPO" branch race/fix-the-login-bugx-claude
  git -C "$REPO" switch -q feature/user-work
  local agents="$STATE_DIR/races/fix-the-login-bug/agents"
  printf 'pi\tmain\t/nonexistent1\t-\t-\tx1\n' >>"$agents"
  printf 'amp\tfeature/user-work\t/nonexistent2\t-\t-\tx2\n' >>"$agents"
  printf 'kimi\trace/fix-the-login-bugx-claude\t/nonexistent3\t-\t-\tx3\n' >>"$agents"
  printf 'kiro\trace/fix-the-login-bug-claude main\t/nonexistent4\t-\t-\tx4\n' >>"$agents"
  run_race cleanup <<<$'fix-the-login-bug\ndelete'
  echo "$output"
  has_branch main
  has_branch feature/user-work
  has_branch race/fix-the-login-bugx-claude
  no_branch race/fix-the-login-bug-claude
}

@test "cleanup never deletes the base branch, even when it looks like a race branch" {
  git -C "$REPO" switch -q -c race/fix-the-login-bug-gemini
  start_race "Fix the login bug"
  git -C "$REPO" switch -q main
  printf 'gemini\trace/fix-the-login-bug-gemini\t/nonexistent\t-\t-\tx\n' >>"$STATE_DIR/races/fix-the-login-bug/agents"
  run_race cleanup <<<$'fix-the-login-bug\ndelete'
  echo "$output"
  has_branch race/fix-the-login-bug-gemini
}

@test "cleanup takes only the race name as confirmation, not yes" {
  start_race "Fix the login bug"
  run_race cleanup <<<"yes"
  echo "$output"
  assert_output_contains "Nothing was removed."
  [ "$(worktrees | awk 'END { print NR }')" = 3 ]
}

@test "each delivery runs in its own process group, so closing the popup does not end it" {
  RUN_ENV+=("STUB_HERDR_START_DELAY=2")
  run_race start <<<$'Fix the login bug\n1 2\ny'
  [ "$status" -eq 0 ]
  local pids pid
  pids="$(delivery_pids)"
  [ -n "$pids" ]
  # Each leads its own process group (pgid = pid), apart from the popup's.
  for pid in $pids; do
    [ "$(ps -o pgid= -p "$pid" | tr -d ' ')" = "$pid" ]
  done
  eventually deliveries_done
}

# --- Manifest, module, and safety -----------------------------------------

@test "the manifest declares jq and git, the three popups, and their actions" {
  run grep -q '^# Requires: jq on PATH, git on PATH' "$PLUGIN_DIR/herdr-plugin.toml"
  [ "$status" -eq 0 ]
  run python3 -I -c '
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    manifest = tomllib.load(handle)
assert manifest["id"] == "oh-my-herdr.agent-race", manifest["id"]
assert manifest["min_herdr_version"] == "0.9.0"
panes = {pane["id"]: pane for pane in manifest["panes"]}
assert sorted(panes) == ["cleanup", "compare", "start"], panes
for pane_id, pane in panes.items():
    assert pane["placement"] == "popup" and pane["command"] == ["sh", "agent-race.sh", pane_id], pane
actions = {action["id"]: action for action in manifest["actions"]}
assert sorted(actions) == ["cleanup", "compare", "start"], actions
for action_id, action in actions.items():
    assert action["command"] == ["sh", "agent-race.sh", "open-" + action_id], action
    assert action["contexts"] == ["pane"], action
assert "startup" not in manifest and "events" not in manifest and "build" not in manifest
' "$PLUGIN_DIR/herdr-plugin.toml"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the module binds prefix+ctrl+r, prefix+ctrl+d, and prefix+ctrl+x to start, compare, and clean up" {
  run grep -q '^# Requires: jq on PATH, git on PATH' "$REPO_ROOT/config/modules/agent-race.toml"
  [ "$status" -eq 0 ]
  run python3 -I -c '
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    commands = {c["key"]: c for c in tomllib.load(handle)["keys"]["command"]}
assert sorted(commands) == ["prefix+ctrl+d", "prefix+ctrl+r", "prefix+ctrl+x"], commands
assert commands["prefix+ctrl+r"]["command"] == "oh-my-herdr.agent-race.start", commands
assert commands["prefix+ctrl+d"]["command"] == "oh-my-herdr.agent-race.compare", commands
assert commands["prefix+ctrl+x"]["command"] == "oh-my-herdr.agent-race.cleanup", commands
assert all(c["type"] == "plugin_action" and c["description"] for c in commands.values()), commands
' "$REPO_ROOT/config/modules/agent-race.toml"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the plugin passes no approval-bypass flag and makes no network calls" {
  run grep -nE -- '--dangerously|skip-permissions|--yolo|--auto-approve|permission-mode|bypass|curl|wget' "$PLUGIN_DIR/agent-race.sh"
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
  printf '%s' "$output" | jq -e '.result.plugins[] | select(.plugin_id == "oh-my-herdr.agent-race" and .enabled)'
}
