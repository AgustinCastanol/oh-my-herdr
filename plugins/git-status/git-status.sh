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
#
# Safety: it runs git in whatever directory a pane is in, so it must not run
# anything a repository configures. The branch name comes from
# `rev-parse` and `symbolic-ref`, which read refs only: no index refresh, no
# filters, no fsmonitor, no hooks. The dirty marker needs `git status`, which
# can run a repository's clean filters, so it is off unless the user creates
# show-dirty in the plugin config directory; even then, has_changes switches
# off fsmonitor, hooks, submodules, and every configured filter driver.

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

# git with the repository settings that can start programs switched off.
safe_git() {
  git -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}

dirty_marker_enabled() {
  [ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ] && [ -f "$HERDR_PLUGIN_CONFIG_DIR/show-dirty" ]
}

# has_changes passes its overrides through GIT_CONFIG_KEY_n/VALUE_n, which
# git reads only from 2.31; an older git would ignore them and could run the
# repository's filters. True when git is new enough. Logs once per run.
git_config_env_checked=''
git_honors_config_env() {
  if [ -z "$git_config_env_checked" ]; then
    git_version=$(git --version 2>/dev/null | sed -n 's/^git version \([0-9][0-9]*\.[0-9][0-9]*[0-9.]*\).*/\1/p')
    git_major=${git_version%%.*}
    git_minor=${git_version#*.}
    git_minor=${git_minor%%.*}
    if [ -z "$git_version" ]; then
      log "could not read the git version; showing the branch without the dirty marker"
      git_config_env_checked=no
    elif [ "$git_major" -gt 2 ] || { [ "$git_major" -eq 2 ] && [ "$git_minor" -ge 31 ]; }; then
      git_config_env_checked=yes
    else
      log "git $git_version is older than 2.31; showing the branch without the dirty marker"
      git_config_env_checked=no
    fi
  fi
  [ "$git_config_env_checked" = yes ]
}

# True when tracked files in $1 differ from the index. Runs in a subshell so
# the git config overrides below do not leak. Overrides go through
# GIT_CONFIG_KEY_n/GIT_CONFIG_VALUE_n, which keep key and value apart even
# when a filter driver's name contains "=" or spaces.
has_changes() (
  changes_dir=$1
  override_count=0
  override() {
    export "GIT_CONFIG_KEY_$override_count=$1" "GIT_CONFIG_VALUE_$override_count=$2"
    override_count=$((override_count + 1))
  }
  override core.fsmonitor false
  override core.hooksPath /dev/null
  # Names only: configured values are repository-controlled text.
  drivers=$(git -C "$changes_dir" config --name-only --get-regexp '^filter\.' 2>/dev/null |
    sed -n -e 's/^filter\.\(.*\)\.clean$/\1/p' -e 's/^filter\.\(.*\)\.smudge$/\1/p' \
      -e 's/^filter\.\(.*\)\.process$/\1/p')
  while IFS= read -r driver; do
    [ -n "$driver" ] || continue
    override "filter.$driver.clean" ''
    override "filter.$driver.smudge" ''
    override "filter.$driver.process" ''
    override "filter.$driver.required" false
  done <<EOF
$drivers
EOF
  export GIT_CONFIG_COUNT="$override_count"
  [ -n "$(git -C "$changes_dir" --no-optional-locks status --porcelain \
    --untracked-files=no --ignore-submodules=all 2>/dev/null | head -n 1)" ]
)

# Print "branch" (with a * when the user enabled the dirty marker and tracked
# files changed) or "@<short commit>" for a detached HEAD. Print nothing
# outside a git work tree.
git_label() {
  label_dir=$1
  [ -d "$label_dir" ] || return 0
  [ "$(safe_git -C "$label_dir" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || return 0
  if ! label=$(safe_git -C "$label_dir" symbolic-ref --quiet --short HEAD 2>/dev/null); then
    label=@$(safe_git -C "$label_dir" rev-parse --short HEAD 2>/dev/null) || return 0
  fi
  if dirty_marker_enabled && git_honors_config_env && has_changes "$label_dir"; then
    label="$label*"
  fi
  printf '%s\n' "$label"
}

# Report the $git token for a pane, or clear it when the directory is not in
# a git work tree. Fails when herdr does not accept the report.
report() {
  report_pane=$1
  report_label=$(git_label "$2")
  if [ -n "$report_label" ]; then
    set -- --token "git=$report_label" --ttl-ms "$TTL_MS"
  else
    set -- --clear-token git
  fi
  if ! "$HERDR" pane report-metadata "$report_pane" --source "$SOURCE" "$@" >/dev/null 2>&1; then
    log "could not report git status for pane $report_pane"
    return 1
  fi
}

stamp_file() {
  printf '%s/refreshed-%s\n' "$HERDR_PLUGIN_STATE_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"
}

# True when the pane was refreshed within DEBOUNCE_SECONDS.
recently_refreshed() {
  [ -n "${HERDR_PLUGIN_STATE_DIR:-}" ] && [ -d "$HERDR_PLUGIN_STATE_DIR" ] || return 1
  last=$(cat "$(stamp_file "$1")" 2>/dev/null)
  case "$last" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ $(($(date +%s) - last)) -lt "$DEBOUNCE_SECONDS" ]
}

# Record a successful refresh, which starts the debounce window.
mark_refreshed() {
  [ -n "${HERDR_PLUGIN_STATE_DIR:-}" ] && [ -d "$HERDR_PLUGIN_STATE_DIR" ] || return 0
  date +%s >"$(stamp_file "$1")" 2>/dev/null
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
  if [ -z "$dir" ]; then
    # A lookup can fail for a moment; keep the current value and let its TTL
    # decide instead of clearing a branch that may still be right.
    log "no working directory for pane $pane; keeping its current value"
    return 0
  fi
  report "$pane" "$dir" && mark_refreshed "$pane"
}

refresh_all_panes() {
  if ! pane_json=$("$HERDR" pane list 2>/dev/null); then
    log "could not list panes"
    return 0
  fi
  if ! panes=$(printf '%s' "$pane_json" |
    jq -r '.result.panes[] | [.pane_id, ((.foreground_cwd // .cwd) // "")] | @tsv' 2>/dev/null); then
    log "could not read the pane list"
    return 0
  fi
  tab=$(printf '\t')
  printf '%s\n' "$panes" | while IFS=$tab read -r pane dir; do
    [ -n "$pane" ] || continue
    if [ -z "$dir" ]; then
      log "no working directory for pane $pane; keeping its current value"
      continue
    fi
    report "$pane" "$dir" && mark_refreshed "$pane"
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
