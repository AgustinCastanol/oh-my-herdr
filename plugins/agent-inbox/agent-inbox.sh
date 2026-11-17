#!/bin/sh
# shellcheck shell=sh
#
# oh-my-herdr agent-inbox plugin.
#
#   agent-inbox.sh sync    at startup: forget earlier records and record the
#                          agents that wait now
#   agent-inbox.sh event   on agent status, focus, and pane exit events: bring
#                          the records and $waiting tokens up to date
#   agent-inbox.sh open    the "open" action: open the popup
#   agent-inbox.sh popup   the popup: list the waiting agents and focus the
#                          one you pick
#
# An agent waits for you while herdr reports it as blocked or done. herdr's
# events carry neither the previous state nor a time, handlers can run at the
# same time, and `herdr agent focus` turns done into idle without a status
# event, so every event re-reads `herdr agent list` instead of trusting the
# event alone. A record is a file in $HERDR_PLUGIN_STATE_DIR/waiting holding
# "PANE STATE EPOCH HH:MM": when the agent entered that state.
#
# Updates never wait for each other. Each one leaves a request (the file
# "rerun", plus "rerun-fresh" at startup) and then tries the lock once; the
# update that holds it serves requests, re-reading the agent list each round,
# so the last round always reads the newest list, and the others return at
# once. After MAX_ROUNDS rounds the holder stops and leaves any request still
# there for the next event, so a burst of events cannot keep it busy.
#
# The lock is a kernel lock on the file "inbox.lock", taken with flock
# (Linux) or lockf (macOS): the kernel releases it when its holder exits or
# dies, so a lock is never left over. Without either tool, a symlink "lock"
# whose target is "PID EPOCH" of its owner is used instead (see take_lock).
#
# It only reads agent state and focuses the agent you pick. It never starts
# an agent or sends one input, and makes no network calls.

HERDR=${HERDR_BIN_PATH:-herdr}
SOURCE=oh-my-herdr.agent-inbox
TOKEN=waiting
# A lock older than this, in seconds, belongs to an update that hung; it is
# left over and taken over.
LOCK_STALE_SECONDS=30
# Most rounds one lock holder serves before it leaves the requests still
# there to the next event, so a burst of events cannot keep it busy.
MAX_ROUNDS=5
# Symlink lock only: most left-over locks one update tries to take over
# before it leaves its request to whoever holds the lock.
TAKEOVER_TRIES=3
# Exit status that means "another update holds the lock" (lockf uses it).
LOCK_BUSY=75
case "$0" in
  */*) SCRIPT=$0 ;;
  *) SCRIPT=./$0 ;;
esac

log() {
  printf 'agent-inbox: %s\n' "$*" >&2
}

wait_for_enter() {
  printf 'Press Enter to close.'
  read -r _ || true
}

# Pane ids look like w1:p2. Anything else is not used in a file name or a
# command.
valid_pane() {
  case "$1" in
    '' | .* | *[!A-Za-z0-9:._-]*) return 1 ;;
  esac
}

record_file() {
  printf '%s/%s' "$RECORDS" "$(printf '%s' "$1" | tr ':' '_')"
}

# Set or clear this plugin's sidebar token on pane $1. Usage:
# report PANE --token waiting=TEXT | report PANE --clear-token waiting
report() {
  report_pane=$1
  shift
  "$HERDR" pane report-metadata "$report_pane" --source "$SOURCE" "$@" >/dev/null 2>&1 ||
    log "could not update the \$$TOKEN token of pane $report_pane"
}

# Print "PANE STATE" for every agent herdr reports as blocked or done; fail
# when the agent list cannot be read.
current_waiting() {
  agents_json=$("$HERDR" agent list 2>/dev/null) || return 1
  printf '%s' "$agents_json" | jq -r '
    if (.result.agents | type) != "array" then error("no agent list") else . end
    | .result.agents[]
    | select((.pane_id | type) == "string")
    | select(.agent_status == "blocked" or .agent_status == "done")
    | "\(.pane_id) \(.agent_status)"
  ' 2>/dev/null
}

# Print the owner of lock symlink $1 ("PID EPOCH"); fail when there is none.
lock_owner() {
  readlink "$1" 2>/dev/null
}

# Succeed when the lock owned by "PID EPOCH" $1 is left over: its process is
# gone or it is older than LOCK_STALE_SECONDS.
lock_is_stale() {
  owner_pid=${1%% *}
  owner_since=${1#* }
  case "$owner_pid" in
    '' | *[!0-9]*) return 0 ;;
  esac
  kill -0 "$owner_pid" 2>/dev/null || return 0
  case "$owner_since" in
    '' | *[!0-9]*) return 0 ;;
  esac
  [ $(($(date +%s) - owner_since)) -gt "$LOCK_STALE_SECONDS" ]
}

# Fallback when neither flock nor lockf exists. The symlink is created
# atomically with its owner, and a left-over lock is moved to a name of our
# own before it is removed, so of several waiters only one takes it over and
# a live lock is put back. One window remains: if a waiter moves a lock that
# changed hands after it was inspected, a third update can take the lock in
# the instant before it is put back, and two updates then overlap once; the
# next event corrects the inbox.
#
# Remove the left-over lock owned by $1, and only that one. The lock is first
# renamed to a name of our own: rename is atomic, so of several waiters only
# one moves it. If what was moved is not the lock that was inspected (it
# changed hands in between), it is put back for its owner, so a live lock is
# never removed. Fails when the lock was not taken over.
take_over() {
  grave="$LOCK.stale.$$"
  mv "$LOCK" "$grave" 2>/dev/null || return 1
  moved=$(lock_owner "$grave")
  if [ "$moved" = "$1" ]; then
    rm -f "$grave"
    log "took over a left-over lock from process ${1%% *}"
    return 0
  fi
  ln -s "$moved" "$LOCK" 2>/dev/null ||
    log "the lock of process ${moved%% *} was replaced while it was put back"
  rm -f "$grave"
  return 1
}

# Take the update lock without waiting: fail when a live update holds it.
take_lock() {
  me="$$ $(date +%s)"
  # A directory here is a lock from an earlier version of this plugin, never
  # a live lock of this one.
  if [ -d "$LOCK" ] && [ ! -L "$LOCK" ]; then
    mv "$LOCK" "$LOCK.old.$$" 2>/dev/null && rm -rf "$LOCK.old.$$"
  fi
  attempts=0
  while ! ln -s "$me" "$LOCK" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -le "$TAKEOVER_TRIES" ] || return 1
    # Released in the meantime: try again.
    owner=$(lock_owner "$LOCK") || continue
    lock_is_stale "$owner" || return 1
    take_over "$owner" || return 1
  done
  trap release_lock EXIT
  trap 'release_lock; exit 1' INT TERM
}

# Remove the lock if it is still ours. Also called from the traps that
# take_lock sets.
release_lock() {
  [ "$(lock_owner "$LOCK")" != "$me" ] || rm -f "$LOCK"
}

# Serve requests until none is left, at most MAX_ROUNDS. Runs while holding
# the lock. Returns 3 when it stops at the cap with a request still there.
serve() {
  rounds=0
  while [ -e "$RERUN" ]; do
    if [ "$rounds" -ge "$MAX_ROUNDS" ]; then
      log "still asked to update after $MAX_ROUNDS rounds; leaving the request for the next event"
      return 3
    fi
    rounds=$((rounds + 1))
    rm -f "$RERUN"
    mode=''
    if [ -e "$RERUN_FRESH" ]; then
      rm -f "$RERUN_FRESH"
      mode=fresh
    fi
    reconcile "$mode"
  done
}

# Print flock or lockf, whichever exists, or nothing.
kernel_lock_tool() {
  if command -v flock >/dev/null 2>&1; then
    printf 'flock\n'
  elif command -v lockf >/dev/null 2>&1; then
    printf 'lockf\n'
  fi
}

# Serve requests under the lock, without waiting for it. Returns LOCK_BUSY
# when another update holds the lock, 3 when serving stopped at the cap.
serve_locked() {
  case "$1" in
    flock) flock -n -E "$LOCK_BUSY" "$KERNEL_LOCK" sh "$SCRIPT" serve ;;
    lockf) lockf -k -s -t 0 "$KERNEL_LOCK" sh "$SCRIPT" serve ;;
    *)
      take_lock || return "$LOCK_BUSY"
      serve
      served=$?
      release_lock
      return "$served"
      ;;
  esac
}

# Bring the inbox up to date: leave a request, then serve requests if the
# lock is free. With "fresh", the round that serves this request starts the
# inbox afresh.
update() {
  mkdir -p "$HERDR_PLUGIN_STATE_DIR" 2>/dev/null
  [ "${1:-}" != fresh ] || : >"$RERUN_FRESH"
  : >"$RERUN"
  tool=$(kernel_lock_tool)
  attempts=0
  # Checked again after the lock is released: a request that arrived after
  # the last round but before the release is served, here or by its sender.
  while [ -e "$RERUN" ]; do
    attempts=$((attempts + 1))
    if [ "$attempts" -gt "$MAX_ROUNDS" ]; then
      log "requests kept arriving after $MAX_ROUNDS update attempts; leaving the request for the next event"
      return 0
    fi
    # Busy: the holder serves the request. Stopped at the cap: the request
    # waits for the next event.
    serve_locked "$tool" || return 0
  done
}

# Make the records and tokens match `herdr agent list`. With "fresh", every
# earlier record is dropped first, so waits are counted from now; that
# happens even when the agent list cannot be read.
reconcile() {
  if ! waiting=$(current_waiting); then
    if [ "${1:-}" != fresh ]; then
      log "could not list agents; leaving the inbox as it is"
      return 0
    fi
    log "could not list agents; starting with an empty inbox"
    waiting=''
  fi
  if ! mkdir -p "$RECORDS"; then
    log "could not create $RECORDS"
    return 0
  fi
  for file in "$RECORDS"/*; do
    [ -f "$file" ] || continue
    pane='' state=''
    read -r pane state _ <"$file" || true
    now_state=$(printf '%s\n' "$waiting" | awk -v pane="$pane" '$1 == pane { print $2; exit }')
    if [ "${1:-}" != fresh ] && [ -n "$now_state" ] && [ "$now_state" = "$state" ]; then
      continue
    fi
    rm -f "$file"
    # An agent that still waits gets a new token below; clear the others.
    if [ -z "$now_state" ] && valid_pane "$pane"; then
      report "$pane" --clear-token "$TOKEN"
    fi
  done
  now=$(date +%s)
  since=$(date +%H:%M)
  printf '%s\n' "$waiting" | while read -r pane state; do
    [ -n "$pane" ] || continue
    if ! valid_pane "$pane"; then
      log "ignoring an agent with an unexpected pane id"
      continue
    fi
    file=$(record_file "$pane")
    [ -f "$file" ] && continue
    # Written under a dot name and moved, so no reader sees half a record.
    temp="$RECORDS/.$(printf '%s' "$pane" | tr ':' '_').$$"
    printf '%s %s %s %s\n' "$pane" "$state" "$now" "$since" >"$temp" && mv "$temp" "$file"
    report "$pane" --token "$TOKEN=$state since $since"
  done
}

# Let the user pick one line of $1; print it, or fail when cancelled. The
# numbered menu goes to stderr because stdout carries the choice.
choose_agent() {
  if command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "$1" | fzf --prompt='agent> ' --reverse --no-multi \
      --header='Agents waiting for you (Enter focuses, Esc closes)'
    return
  fi
  {
    printf 'Agents waiting for you, longest wait first:\n'
    printf '%s\n' "$1" | awk '{ printf "%3d) %s\n", NR, $0 }'
    printf 'Type a number and press Enter to focus that agent (Enter alone closes): '
  } >&2
  read -r answer || return 1
  case "$answer" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$answer" -ge 1 ] || return 1
  printf '%s\n' "$1" | sed -n "${answer}p"
}

# One line per waiting agent: blocked before done, longest wait first. An
# agent without a matching record has waited since before the plugin saw it
# and counts from now. The $ names are jq variables, not shell expansions.
# shellcheck disable=SC2016
INBOX_JQ='
def two: tostring | if length < 2 then "0" + . else . end;
def wait_text:
  if . < 60 then "<1m"
  elif . < 3600 then "\(. / 60 | floor)m"
  else "\(. / 3600 | floor)h\(. % 3600 / 60 | floor | two)m"
  end;
($records | split("\n") | map(split(" ") | select(length >= 3)
  | {key: .[0], value: {state: .[1], since: (.[2] | tonumber? // null)}}) | from_entries) as $recorded
| ($workspaces | fromjson? // {} | .result.workspaces // []
  | map({key: .workspace_id, value: (.label // .workspace_id)}) | from_entries) as $workspace_label
| ($tabs | fromjson? // {} | .result.tabs // []
  | map({key: .tab_id, value: (.label // .tab_id)}) | from_entries) as $tab_label
| [ $agents | fromjson | .result.agents[]
    | select((.pane_id | type) == "string" and .pane_id != "")
    | select(.agent_status == "blocked" or .agent_status == "done")
    | ($recorded[.pane_id] // {}) as $record
    | ((.foreground_cwd // .cwd // "") as $cwd
       | if $cwd == "" then "?" else ($cwd | split("/") | map(select(length > 0)) | last // "/") end) as $dir
    | { pane: .pane_id, state: .agent_status,
        since: (if $record.state == .agent_status and $record.since != null then $record.since else $now end),
        name: (.name // .display_agent // .agent // "agent"),
        place: "\($workspace_label[.workspace_id // ""] // .workspace_id // "?")/\($tab_label[.tab_id // ""] // .tab_id // "?")",
        dir: $dir } ]
| sort_by((if .state == "blocked" then 0 else 1 end), .since)
| .[]
| "\(.pane)  \(.state)  \(.name)  \(.place)  \(.dir)  waiting \($now - .since | if . < 0 then 0 else . end | wait_text)"
'

popup() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'agent-inbox needs jq, which is not on PATH.\n'
    wait_for_enter
    return 0
  fi
  if ! agents_json=$("$HERDR" agent list 2>/dev/null) ||
    ! printf '%s' "$agents_json" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1; then
    reason=$(printf '%s' "$agents_json" | jq -r '.error.message // empty' 2>/dev/null)
    reason=${reason:-$agents_json}
    printf 'Could not read the agent list: %s\n' "${reason:-herdr agent list printed nothing}"
    wait_for_enter
    return 0
  fi
  workspaces_json=$("$HERDR" workspace list 2>/dev/null) || workspaces_json=''
  tabs_json=$("$HERDR" tab list 2>/dev/null) || tabs_json=''
  records=''
  for file in "$RECORDS"/*; do
    [ -f "$file" ] || continue
    records="$records$(cat "$file")
"
  done
  if ! lines=$(jq -rn --argjson now "$(date +%s)" --arg records "$records" --arg agents "$agents_json" \
    --arg workspaces "$workspaces_json" --arg tabs "$tabs_json" "$INBOX_JQ" 2>&1); then
    printf 'Could not read the agent list: %s\n' "$lines"
    wait_for_enter
    return 0
  fi
  if [ -z "$lines" ]; then
    printf 'No agents are waiting for you.\n'
    wait_for_enter
    return 0
  fi
  choice=$(choose_agent "$lines") || return 0
  target=${choice%%  *}
  valid_pane "$target" || return 0
  if result=$("$HERDR" agent focus "$target" 2>&1) &&
    ! printf '%s' "$result" | jq -e '.error' >/dev/null 2>&1; then
    return 0
  fi
  reason=$(printf '%s' "$result" | jq -r '.error.message // empty' 2>/dev/null)
  printf 'Could not focus %s: %s\n' "$target" "${reason:-$result}"
  wait_for_enter
}

open_popup() {
  "$HERDR" plugin pane open --plugin "$SOURCE" --entrypoint inbox >/dev/null 2>&1 ||
    log "could not open the popup"
}

# herdr always sets the state directory; without it there is nowhere safe
# to keep records.
if [ -n "${HERDR_PLUGIN_STATE_DIR:-}" ]; then
  RECORDS="$HERDR_PLUGIN_STATE_DIR/waiting"
  LOCK="$HERDR_PLUGIN_STATE_DIR/lock"
  KERNEL_LOCK="$HERDR_PLUGIN_STATE_DIR/inbox.lock"
  RERUN="$HERDR_PLUGIN_STATE_DIR/rerun"
  RERUN_FRESH="$HERDR_PLUGIN_STATE_DIR/rerun-fresh"
else
  RECORDS=''
fi

case "${1:-}" in
  sync | event | serve)
    if [ -z "$RECORDS" ]; then
      log "HERDR_PLUGIN_STATE_DIR is not set; nothing recorded"
    elif ! command -v jq >/dev/null 2>&1; then
      log "jq is not on PATH; the inbox is not updated"
    elif [ "$1" = sync ]; then
      update fresh
    elif [ "$1" = serve ]; then
      serve || exit "$?"
    else
      update
    fi
    ;;
  popup) popup ;;
  open) open_popup ;;
  *) log "unknown mode '${1:-}'; expected sync, event, serve, open, or popup" ;;
esac
exit 0
