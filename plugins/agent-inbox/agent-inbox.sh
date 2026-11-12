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
# It only reads agent state and focuses the agent you pick. It never starts
# an agent or sends one input, and makes no network calls.

HERDR=${HERDR_BIN_PATH:-herdr}
SOURCE=oh-my-herdr.agent-inbox
TOKEN=waiting

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
    | select(.agent_status == "blocked" or .agent_status == "done")
    | "\(.pane_id) \(.agent_status)"
  ' 2>/dev/null
}

# Make the records and tokens match `herdr agent list`. With "fresh", every
# earlier record is dropped first, so waits are counted from now.
reconcile() {
  if ! waiting=$(current_waiting); then
    log "could not list agents; leaving the inbox as it is"
    return 0
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
  agents_json=$("$HERDR" agent list 2>/dev/null)
  if ! printf '%s' "$agents_json" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1; then
    printf 'agent-inbox: could not list the agents.\n'
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
  lines=$(jq -rn --argjson now "$(date +%s)" --arg records "$records" --arg agents "$agents_json" \
    --arg workspaces "$workspaces_json" --arg tabs "$tabs_json" "$INBOX_JQ" 2>/dev/null)
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
else
  RECORDS=''
fi

case "${1:-}" in
  sync | event)
    if [ -z "$RECORDS" ]; then
      log "HERDR_PLUGIN_STATE_DIR is not set; nothing recorded"
    elif ! command -v jq >/dev/null 2>&1; then
      log "jq is not on PATH; the inbox is not updated"
    elif [ "$1" = sync ]; then
      reconcile fresh
    else
      reconcile
    fi
    ;;
  popup) popup ;;
  open) open_popup ;;
  *) log "unknown mode '${1:-}'; expected sync, event, open, or popup" ;;
esac
exit 0
