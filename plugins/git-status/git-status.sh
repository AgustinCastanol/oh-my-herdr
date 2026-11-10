#!/bin/sh
# shellcheck shell=sh
#
# oh-my-herdr git-status plugin: report each pane's git branch to herdr as
# the $git sidebar token.
#
#   git-status.sh all     every pane (startup hook and the refresh action)
#   git-status.sh event   the pane in HERDR_PLUGIN_EVENT_JSON (pane.created,
#                         pane.focused)
#
# This runs inside herdr, so it never fails loudly: on any problem it writes
# one line to stderr, which herdr keeps in the plugin log, and exits 0.

SOURCE=oh-my-herdr.git-status
# Values expire after this long unless refreshed, so a branch that changed
# without a new event (for example after `git switch` in a focused pane)
# disappears instead of staying wrong.
TTL_MS=600000
# A pane refreshed less than this many seconds ago is skipped, because focus
# events can arrive in quick bursts.
DEBOUNCE_SECONDS=2

HERDR=${HERDR_BIN_PATH:-herdr}

log() {
  printf 'git-status: %s\n' "$*" >&2
}

# Print "branch", "branch*" when tracked files have uncommitted changes, or
# "@<short commit>" for a detached HEAD. Print nothing outside a git work tree.
git_label() {
  label_dir=$1
  [ -n "$label_dir" ] && [ -d "$label_dir" ] || return 0
  git -C "$label_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  if ! label=$(git -C "$label_dir" symbolic-ref --quiet --short HEAD 2>/dev/null); then
    label=@$(git -C "$label_dir" rev-parse --short HEAD 2>/dev/null) || return 0
  fi
  if [ -n "$(git -C "$label_dir" --no-optional-locks status --porcelain --untracked-files=no 2>/dev/null | head -n 1)" ]; then
    label="$label*"
  fi
  printf '%s\n' "$label"
}

# Report the $git token for a pane, or clear it when the directory is not in
# a git work tree.
report() {
  report_pane=$1
  report_label=$(git_label "$2")
  if [ -n "$report_label" ]; then
    set -- --token "git=$report_label" --ttl-ms "$TTL_MS"
  else
    set -- --clear-token git
  fi
  "$HERDR" pane report-metadata "$report_pane" --source "$SOURCE" "$@" >/dev/null 2>&1 ||
    log "could not report git status for pane $report_pane"
}

# True when the pane was refreshed within DEBOUNCE_SECONDS; otherwise record
# this refresh and return false.
recently_refreshed() {
  [ -n "${HERDR_PLUGIN_STATE_DIR:-}" ] && [ -d "$HERDR_PLUGIN_STATE_DIR" ] || return 1
  stamp_file=$HERDR_PLUGIN_STATE_DIR/refreshed-$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')
  now=$(date +%s)
  last=$(cat "$stamp_file" 2>/dev/null)
  case "$last" in
    '' | *[!0-9]*) ;;
    *) [ $((now - last)) -ge "$DEBOUNCE_SECONDS" ] || return 0 ;;
  esac
  printf '%s\n' "$now" >"$stamp_file" 2>/dev/null
  return 1
}

# Print the working directory herdr reports for a pane, preferring the
# directory of the process in the foreground (an agent started in a subdir).
pane_dir() {
  "$HERDR" pane get "$1" 2>/dev/null |
    jq -r '.result.pane | (.foreground_cwd // .cwd) // empty' 2>/dev/null
}

refresh_event_pane() {
  event_json=${HERDR_PLUGIN_EVENT_JSON:-}
  pane=$(printf '%s' "$event_json" |
    jq -r '.data.pane.pane_id // .data.pane_id // empty' 2>/dev/null)
  # herdr also sets HERDR_PANE_ID for pane events.
  [ -n "$pane" ] || pane=${HERDR_PANE_ID:-}
  if [ -z "$pane" ]; then
    log "no pane in the event ${HERDR_PLUGIN_EVENT:-}; nothing to do"
    return 0
  fi
  recently_refreshed "$pane" && return 0
  # pane.created carries the pane with its cwd; pane.focused only its id.
  dir=$(printf '%s' "$event_json" |
    jq -r '.data.pane | (.foreground_cwd // .cwd) // empty' 2>/dev/null)
  [ -n "$dir" ] || dir=$(pane_dir "$pane")
  report "$pane" "$dir"
}

refresh_all_panes() {
  if ! panes=$("$HERDR" pane list 2>/dev/null |
    jq -r '.result.panes[] | [.pane_id, ((.foreground_cwd // .cwd) // "")] | @tsv' 2>/dev/null); then
    log "could not list panes"
    return 0
  fi
  tab=$(printf '\t')
  printf '%s\n' "$panes" | while IFS=$tab read -r pane dir; do
    [ -n "$pane" ] || continue
    report "$pane" "$dir"
  done
}

for tool in git jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    log "$tool is not on PATH; nothing to do"
    exit 0
  fi
done

case "${1:-}" in
  all) refresh_all_panes ;;
  event) refresh_event_pane ;;
  *) log "unknown mode '${1:-}'; expected all or event" ;;
esac
exit 0
