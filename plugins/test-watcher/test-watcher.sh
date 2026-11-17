#!/bin/sh
# shellcheck shell=sh
#
# oh-my-herdr test-watcher plugin.
#
#   test-watcher.sh toggle | watch | stop   actions on the focused pane
#   test-watcher.sh send       action: open agent-handoff's fix-failing-tests
#                              prompt for the focused pane
#   test-watcher.sh event      on pane.exited and pane.closed: stop that
#                              pane's watcher
#   test-watcher.sh startup    at startup: stop watchers from before
#   test-watcher.sh run PANE   the watcher itself, started by watch
#   test-watcher.sh classify   print "fail", "pass", or nothing for the text
#                              on stdin, to try out a patterns file
#
# A watcher reads the last WINDOW_LINES lines of its pane every few seconds
# and, when they changed, looks for the last line that matches a failure or
# success pattern. herdr's `pane wait-output` also matches output that is
# already on screen, so it cannot tell a new result from an old one, and its
# pane.output_matched events need a socket subscription that plugins do not
# get; reading a window and comparing its checksum, with sleeps in between,
# needs neither and never spins.
#
# A watcher's pid is in $HERDR_PLUGIN_STATE_DIR/watchers/<pane>.pid and its
# problems go to <pane>.log next to it. It stops when its pane is gone, when
# herdr reports the pane closed or exited, and at startup. The plugin never
# sends anything to an agent: the send action only opens agent-handoff's
# popup, which shows a preview and asks for confirmation.

HERDR=${HERDR_BIN_PATH:-herdr}
SOURCE=oh-my-herdr.test-watcher
TOKEN=tests
# Most panes watched at once.
MAX_WATCHERS=8
# Lines at the end of the pane that a watcher reads.
WINDOW_LINES=60
# Seconds between reads: FAST_SECONDS right after the output changed, then
# one more each time it did not, up to SLOW_SECONDS.
FAST_SECONDS=2
SLOW_SECONDS=6
# Failed reads in a row (other than "pane not found") before a watcher
# stops; the wait doubles after each, up to MAX_BACKOFF_SECONDS, and is back
# to FAST_SECONDS after the next read that works.
ERROR_LIMIT=5
MAX_BACKOFF_SECONDS=30
# Tries of 0.1 seconds (about 2 seconds) that stopping waits for a watcher to
# exit, which is usually long enough for a report it is in the middle of. A
# slower report can still land after the stop's clear; the watcher then sees
# it was stopped and clears its own token before it exits.
STOP_WAIT_TRIES=20
case "$0" in
  */*) SCRIPT=$0 ;;
  *) SCRIPT=./$0 ;;
esac

# Default patterns, POSIX extended regular expressions matched against one
# line at a time; see the README for the patterns file that replaces them.
DEFAULT_PATTERNS='
# A count of failures or errors that is not zero: jest, vitest, pytest,
# cargo, mocha, rspec, tsc.
fail (^|[^0-9])[1-9][0-9]* (failed|failing|failures?|errors?)([^a-z]|$)
fail ^ *FAIL([[:space:]:]|$)
fail ^--- FAIL:
fail ^FAILED[[:space:]]
fail test result: FAILED
fail ^Error:
fail ^error(\[E[0-9]+\])?:
fail error TS[0-9]+:
fail ^make(\[[0-9]+\])?: [*][*][*]
fail ^npm ERR!
# A count of passes that is not zero, and the runners own "ok" lines.
pass (^|[^0-9])[1-9][0-9]* (passed|passing)([^a-z]|$)
pass test result: ok[.]
pass ^ok[[:space:]]
pass ^ *PASS([[:space:]]|$)
pass [0-9]+ examples?, 0 failures
'

log() {
  printf 'test-watcher: %s\n' "$*" >&2
}

valid_pane() {
  case "$1" in
    '' | .* | *[!A-Za-z0-9:._-]*) return 1 ;;
  esac
}

pid_file_of() {
  printf '%s/%s.pid' "$WATCHERS" "$(printf '%s' "$1" | tr ':' '_')"
}

# Set or clear this plugin's sidebar token on pane $1.
report() {
  report_pane=$1
  shift
  "$HERDR" pane report-metadata "$report_pane" --source "$SOURCE" "$@" >/dev/null 2>&1 ||
    log "could not update the \$$TOKEN token of pane $report_pane"
}

notify() {
  "$HERDR" notification show "$1" --body "$2" >/dev/null 2>&1 ||
    log "could not show the notification: $1: $2"
}

# Print "fail", "pass", or nothing for the text on stdin: the last line that
# matches decides. Lines matching an "ignore" pattern are skipped. A patterns
# file with "fail" lines replaces the default failure patterns, one with
# "pass" lines the default success patterns; "ignore" lines add to them.
classify() {
  user=''
  if [ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ] && [ -f "$HERDR_PLUGIN_CONFIG_DIR/patterns" ]; then
    user=$(cat "$HERDR_PLUGIN_CONFIG_DIR/patterns")
  fi
  OMH_DEFAULT_PATTERNS=$DEFAULT_PATTERNS OMH_USER_PATTERNS=$user awk '
    function load(text, from,   count, i, lines, line, kind, re) {
      count = split(text, lines, "\n")
      for (i = 1; i <= count; i++) {
        line = lines[i]
        sub(/\r$/, "", line)
        sub(/^[ \t]+/, "", line)
        if (line == "" || line ~ /^#/) continue
        kind = line
        sub(/[ \t].*$/, "", kind)
        re = line
        sub(/^[^ \t]+[ \t]+/, "", re)
        if (re == line) continue
        if (kind != "fail" && kind != "pass" && kind != "ignore") continue
        loaded[from, kind]++
        loaded_re[from, kind, loaded[from, kind]] = re
      }
    }
    function use(kind, from,   i) {
      for (i = 1; i <= loaded[from, kind]; i++) {
        n[kind]++
        re[kind, n[kind]] = loaded_re[from, kind, i]
      }
    }
    BEGIN {
      load(ENVIRON["OMH_DEFAULT_PATTERNS"], "default")
      load(ENVIRON["OMH_USER_PATTERNS"], "user")
      use("fail", (loaded["user", "fail"] > 0) ? "user" : "default")
      use("pass", (loaded["user", "pass"] > 0) ? "user" : "default")
      use("ignore", "default")
      use("ignore", "user")
    }
    {
      for (i = 1; i <= n["ignore"]; i++) if ($0 ~ re["ignore", i]) next
      for (i = 1; i <= n["fail"]; i++) if ($0 ~ re["fail", i]) { result = "fail"; next }
      for (i = 1; i <= n["pass"]; i++) if ($0 ~ re["pass", i]) { result = "pass"; next }
    }
    END { if (result != "") print result }
  '
}

# Print the pid of pane $1's watcher, and fail when there is none. A pid only
# counts when ps shows that very watcher, so a pid file left over from before
# never gets an unrelated process stopped.
watcher_pid() {
  pid=$(cat "$(pid_file_of "$1")" 2>/dev/null) || return 1
  case "$pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  args=$(ps -p "$pid" -o args= 2>/dev/null) || return 1
  args=${args%"${args##*[! ]}"}
  case "$args" in
    *"test-watcher.sh run $1") printf '%s\n' "$pid" ;;
    *) return 1 ;;
  esac
}

# Print "name (pane ID)" for pane $1: its label, terminal title, or directory.
pane_name() {
  name=$("$HERDR" pane get "$1" 2>/dev/null | jq -r '
    .result.pane
    | .label // .terminal_title_stripped
      // ((.foreground_cwd // .cwd // "") | split("/") | map(select(length > 0)) | last)
      // empty
  ' 2>/dev/null)
  if [ -n "$name" ]; then
    printf '%s (pane %s)' "$name" "$1"
  else
    printf 'pane %s' "$1"
  fi
}

# Sleep $1 seconds in a way a signal interrupts at once.
nap() {
  sleep "$1" &
  nap_pid=$!
  wait "$nap_pid" 2>/dev/null
  nap_pid=''
}

# Called from the EXIT trap of a watcher.
# shellcheck disable=SC2329
watcher_exit() {
  [ -z "$nap_pid" ] || kill "$nap_pid" 2>/dev/null
  # Only the watcher that owns the pid file cleans up after itself, and a
  # pane that is gone has no token left to clear.
  if [ "$(cat "$pid_file" 2>/dev/null)" = "$$" ]; then
    rm -f "$pid_file"
    [ "$pane_gone" = 1 ] || [ "$cleared" = 1 ] || report "$pane" --clear-token "$TOKEN"
  fi
}

# Return while this watcher still owns its pane; otherwise exit. Stopped
# (a signal arrived, or its pid file is gone): clear the token first, since
# a report of ours may have landed after the stop's clear. Taken over by
# another watcher: leave that watcher's token alone.
still_watching() {
  owner=$(cat "$pid_file" 2>/dev/null)
  if [ "$stopped" = 0 ] && [ "$owner" = "$$" ]; then
    return 0
  fi
  if [ -z "$owner" ] || [ "$owner" = "$$" ]; then
    [ "$pane_gone" = 1 ] || report "$pane" --clear-token "$TOKEN"
    cleared=1
  fi
  exit 0
}

# Set the token, checking just before and just after that this watcher
# still owns the pane, so a stop during a slow report leaves no token.
report_if_watching() {
  still_watching
  report "$pane" "$@"
  still_watching
}

# Act on result $1 of a read. Only a change counts: a pane that starts
# failing gets the failing token, with a notification unless it was already
# failing when watching started; one that passes gets the passing token.
# With no result (nothing on screen matches), the last one stays.
apply_result() {
  [ -n "$1" ] && [ "$1" != "$state" ] || return 0
  case "$1" in
    fail)
      [ "$classified" = 0 ] || notify "Tests failing" "$(pane_name "$pane")"
      report_if_watching --token "$TOKEN=✗ failing since $(date +%H:%M)"
      ;;
    pass)
      report_if_watching --token "$TOKEN=✓ passing"
      ;;
  esac
  state=$1
}

# The watcher for pane $1.
run_watcher() {
  pane=$1
  valid_pane "$pane" || exit 0
  mkdir -p "$WATCHERS" || exit 0
  pid_file=$(pid_file_of "$pane")
  # Claim the pane. A live watcher of the same pane keeps it; a pid file
  # left over is replaced once.
  if ! (set -C && printf '%s\n' "$$" >"$pid_file") 2>/dev/null; then
    watcher_pid "$pane" >/dev/null && exit 0
    rm -f "$pid_file"
    (set -C && printf '%s\n' "$$" >"$pid_file") 2>/dev/null || exit 0
  fi
  nap_pid=''
  pane_gone=0
  stopped=0
  cleared=0
  trap watcher_exit EXIT
  # A signal only marks the watcher stopped: it then leaves at its next
  # check (still_watching), after a report it is in the middle of.
  trap 'stopped=1' TERM INT HUP
  report_if_watching --token "$TOKEN=watching"

  state=''
  fingerprint=''
  classified=0
  interval=$FAST_SECONDS
  errors=0
  while :; do
    # Stopped, or another watcher took the pane over: leave.
    still_watching
    if window=$("$HERDR" pane read "$pane" --source recent-unwrapped --lines "$WINDOW_LINES" 2>/dev/null); then
      # Reading works again after errors: back to the fast interval.
      [ "$errors" = 0 ] || interval=$FAST_SECONDS
      errors=0
      sum=$(printf '%s' "$window" | cksum)
      if [ "$sum" != "$fingerprint" ]; then
        fingerprint=$sum
        interval=$FAST_SECONDS
        if result=$(printf '%s\n' "$window" | classify); then
          apply_result "$result"
          classified=1
        else
          log "could not apply the test patterns in ${HERDR_PLUGIN_CONFIG_DIR:-the plugin config directory}/patterns"
        fi
      elif [ "$interval" -lt "$SLOW_SECONDS" ]; then
        interval=$((interval + 1))
      fi
    else
      # herdr reports a missing pane on stdout but a missing server on
      # stderr, so ask once more to see both. Either way the pane is gone.
      why=$("$HERDR" pane read "$pane" --lines 1 2>&1)
      case "$window $why" in
        *'"pane_not_found"'* | *'"server_not_running"'*)
          pane_gone=1
          exit 0
          ;;
      esac
      errors=$((errors + 1))
      if [ "$errors" -ge "$ERROR_LIMIT" ]; then
        log "could not read pane $pane $ERROR_LIMIT times in a row; stopping"
        exit 0
      fi
      interval=$((interval * 2))
      [ "$interval" -le "$MAX_BACKOFF_SECONDS" ] || interval=$MAX_BACKOFF_SECONDS
    fi
    nap "$interval"
  done
}

# Stop pane $1's watcher and clear its token, unless $2 is "gone" (the pane
# no longer exists, so there is no token to clear).
stop_watcher() {
  if pid=$(watcher_pid "$1"); then
    kill "$pid" 2>/dev/null
    # It exits once a report it is in the middle of is done; wait for that,
    # so the clear below is the last word on the token.
    tries=0
    while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt "$STOP_WAIT_TRIES" ]; do
      sleep 0.1 2>/dev/null || sleep 1
      tries=$((tries + 1))
    done
  fi
  rm -f "$(pid_file_of "$1")"
  [ "${2:-}" = gone ] || report "$1" --clear-token "$TOKEN"
}

# Count the watchers that are running.
live_watchers() {
  count=0
  for file in "$WATCHERS"/*.pid; do
    [ -f "$file" ] || continue
    pid=$(cat "$file" 2>/dev/null)
    case "$pid" in
      '' | *[!0-9]*) continue ;;
    esac
    case "$(ps -p "$pid" -o args= 2>/dev/null)" in
      *"test-watcher.sh run "*) count=$((count + 1)) ;;
    esac
  done
  printf '%s\n' "$count"
}

start_watcher() {
  if watcher_pid "$1" >/dev/null; then
    log "pane $1 is already watched"
    return 0
  fi
  if [ "$(live_watchers)" -ge "$MAX_WATCHERS" ]; then
    notify "Test watcher" "Already watching $MAX_WATCHERS panes; stop one before watching another."
    log "already watching $MAX_WATCHERS panes"
    return 0
  fi
  mkdir -p "$WATCHERS" || return 0
  log_file="$WATCHERS/$(printf '%s' "$1" | tr ':' '_').log"
  nohup sh "$SCRIPT" run "$1" </dev/null >/dev/null 2>"$log_file" &
}

# Set pane to the pane the action ran on, and cwd to its directory when
# herdr gave it. Fails when there is no usable pane.
action_pane() {
  context=${HERDR_PLUGIN_CONTEXT_JSON:-}
  pane=$(printf '%s' "$context" | jq -r '.focused_pane_id // empty' 2>/dev/null)
  cwd=''
  if [ -n "$pane" ]; then
    cwd=$(printf '%s' "$context" | jq -r '.focused_pane_cwd // empty' 2>/dev/null)
  else
    pane=${HERDR_PANE_ID:-}
  fi
  valid_pane "$pane"
}

# Open agent-handoff's prompt popup on the fix-failing-tests prompt, with the
# pane as the origin. agent-handoff shows the preview and asks before it
# sends anything.
send_failure() {
  set -- --plugin oh-my-herdr.agent-handoff --entrypoint prompts --env "OMH_HANDOFF_PANE=$pane"
  [ -z "$cwd" ] || set -- "$@" --env "OMH_HANDOFF_CWD=$cwd"
  set -- "$@" --env "OMH_HANDOFF_PROMPT=fix-failing-tests.md"
  if ! result=$("$HERDR" plugin pane open "$@" 2>&1); then
    reason=$(printf '%s' "$result" | jq -r '.error.message // empty' 2>/dev/null)
    notify "Test watcher" "Could not open the agent-handoff prompt popup: ${reason:-is the agent-handoff plugin installed and enabled?}"
  fi
}

# At startup, no pane from before exists: stop every watcher and forget it.
startup() {
  for file in "$WATCHERS"/*.pid; do
    [ -f "$file" ] || continue
    pid=$(cat "$file" 2>/dev/null)
    rm -f "$file"
    case "$pid" in
      '' | *[!0-9]*) continue ;;
    esac
    args=$(ps -p "$pid" -o args= 2>/dev/null) || continue
    case "$args" in
      *"test-watcher.sh run "*) kill "$pid" 2>/dev/null ;;
    esac
  done
}

if [ -n "${HERDR_PLUGIN_STATE_DIR:-}" ]; then
  WATCHERS="$HERDR_PLUGIN_STATE_DIR/watchers"
else
  WATCHERS=''
fi

case "${1:-}" in
  classify)
    if ! result=$(classify); then
      log "could not apply the test patterns in ${HERDR_PLUGIN_CONFIG_DIR:-the plugin config directory}/patterns"
      exit 1
    fi
    [ -z "$result" ] || printf '%s\n' "$result"
    exit 0
    ;;
esac

if [ -z "$WATCHERS" ]; then
  log "HERDR_PLUGIN_STATE_DIR is not set; nothing to do"
  exit 0
fi

case "${1:-}" in
  run) run_watcher "${2:-}" ;;
  startup) startup ;;
  event)
    if ! command -v jq >/dev/null 2>&1; then
      log "jq is not on PATH"
      exit 0
    fi
    pane=$(printf '%s' "${HERDR_PLUGIN_EVENT_JSON:-}" | jq -r '.data.pane_id // .data.pane.pane_id // empty' 2>/dev/null)
    [ -n "$pane" ] || pane=${HERDR_PANE_ID:-}
    if valid_pane "$pane" && [ -f "$(pid_file_of "$pane")" ]; then
      stop_watcher "$pane" gone
    fi
    ;;
  toggle | watch | stop | send)
    if ! command -v jq >/dev/null 2>&1; then
      log "jq is not on PATH"
      exit 0
    fi
    if ! action_pane; then
      log "no pane to act on"
      exit 0
    fi
    case "$1" in
      toggle)
        if watcher_pid "$pane" >/dev/null; then
          stop_watcher "$pane"
        else
          start_watcher "$pane"
        fi
        ;;
      watch) start_watcher "$pane" ;;
      stop) stop_watcher "$pane" ;;
      send) send_failure ;;
    esac
    ;;
  *) log "unknown mode '${1:-}'; expected toggle, watch, stop, send, event, startup, run, or classify" ;;
esac
exit 0
