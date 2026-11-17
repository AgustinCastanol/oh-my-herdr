#!/bin/sh
# shellcheck shell=sh
#
# oh-my-herdr workspace-explorer plugin: an oil.nvim-style directory browser
# whose only action is opening a herdr workspace at a directory.
#
#   workspace-explorer.sh open     the "open" action: open the popup at the
#                                  focused pane's directory
#   workspace-explorer.sh browse   the popup
#
# Directories are listed with shell globs and file tests (-d, -L, -e): no
# program runs in a browsed directory (a project is a directory containing
# .git, checked with -e only), and no file is created, changed, or deleted. The only change it makes is in herdr: `herdr workspace focus` for
# a workspace already at the chosen directory, or `herdr workspace create`.

HERDR=${HERDR_BIN_PATH:-herdr}
NL='
'
TAB=$(printf '\t')

# Print the real path of directory $1 (symlinks resolved), or fail.
real_dir() {
  (cd "$1" 2>/dev/null && pwd -P)
}

# Set dirs and files (names, one per line, sorted) for the directory $dir,
# and skipped to the number of names with a line break or tab, which a
# line-based list cannot show safely.
list_dir() {
  dirs=''
  files=''
  skipped=0
  for entry in "$base"/* "$base"/.*; do
    name=${entry##*/}
    case "$name" in
      . | ..) continue ;;
    esac
    # An unmatched glob stays as written and names nothing.
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    case "$name" in
      .*) [ "$show_hidden" = 1 ] || continue ;;
    esac
    case "$name" in
      *"$NL"* | *"$TAB"*)
        skipped=$((skipped + 1))
        continue
        ;;
    esac
    if [ -d "$entry" ]; then
      dirs="$dirs$name$NL"
    else
      files="$files$name$NL"
    fi
  done
  dirs=$(printf '%s' "$dirs" | LC_ALL=C sort)
  files=$(printf '%s' "$files" | LC_ALL=C sort)
}

# Set lines (what is shown) and names (the entry of each line, same order):
# ../ first, then directories with a trailing /, then files. Symlinks and
# projects (containing .git) are marked.
render() {
  lines='../'
  names='..'
  old_ifs=$IFS
  IFS=$NL
  set -f
  for name in $dirs; do
    line="$name/"
    [ ! -L "$base/$name" ] || line="$line  [symlink]"
    [ ! -e "$base/$name/.git" ] || line="$line  [project]"
    lines="$lines$NL$line"
    names="$names$NL$name"
  done
  for name in $files; do
    line=$name
    [ ! -L "$base/$name" ] || line="$line  [symlink]"
    lines="$lines$NL$line"
    names="$names$NL$name"
  done
  set +f
  IFS=$old_ifs
}

# Go into directory $1 if it can be listed; otherwise say so and stay.
enter_dir() {
  if target=$(real_dir "$1") && [ -r "$target" ] && [ -x "$target" ]; then
    dir=$target
  else
    message="Cannot open $1: it is not readable."
  fi
}

go_up() {
  if [ "$dir" = / ]; then
    message='Already at /.'
    return 0
  fi
  parent=${dir%/*}
  enter_dir "${parent:-/}"
}

# Print the label for a new workspace at directory $1: its name, or
# "parent/name" when another workspace already uses the name.
new_label() {
  name=${1##*/}
  [ -n "$name" ] || name=/
  if printf '%s' "$workspaces" | NAME=$name jq -e '.result.workspaces[]? | select(.label == env.NAME)' >/dev/null 2>&1; then
    parent=${1%/*}
    parent_name=${parent##*/}
    name="${parent_name:-}/$name"
  fi
  printf '%s\n' "$name"
}

# Open a herdr workspace at directory $1: focus one that is already there (a
# worktree checkout or a pane in that directory, compared as real paths), or
# create one. Fails, with a message, when it could not.
open_at() {
  if ! command -v jq >/dev/null 2>&1; then
    message='Opening a workspace needs jq, which is not on PATH.'
    return 1
  fi
  if ! target=$(real_dir "$1"); then
    message="Cannot open $1."
    return 1
  fi
  workspaces=$("$HERDR" workspace list 2>/dev/null) || workspaces=''
  panes=$("$HERDR" pane list 2>/dev/null) || panes=''
  candidates=$({
    printf '%s' "$workspaces" | jq -r '.result.workspaces[]? | select(.worktree.checkout_path? != null)
      | "\(.workspace_id)\t\(.worktree.checkout_path)"'
    printf '%s' "$panes" | jq -r '.result.panes[]? | select(.workspace_id != null)
      | "\(.workspace_id)\t\(.cwd // "")", "\(.workspace_id)\t\(.foreground_cwd // "")"'
  } 2>/dev/null)
  existing=''
  while IFS=$TAB read -r workspace path; do
    [ -n "$workspace" ] && [ -n "$path" ] || continue
    if [ "$(real_dir "$path")" = "$target" ]; then
      existing=$workspace
      break
    fi
  done <<EOF
$candidates
EOF
  if [ -n "$existing" ]; then
    if result=$("$HERDR" workspace focus "$existing" 2>&1) &&
      ! printf '%s' "$result" | jq -e '.error' >/dev/null 2>&1; then
      printf 'Focused workspace %s, which is already at %s.\n' "$existing" "$target"
      return 0
    fi
  else
    label=$(new_label "$target")
    if result=$("$HERDR" workspace create --cwd "$target" --label "$label" --focus 2>&1) &&
      ! printf '%s' "$result" | jq -e '.error' >/dev/null 2>&1; then
      printf 'Opened workspace %s at %s.\n' "$label" "$target"
      return 0
    fi
  fi
  reason=$(printf '%s' "$result" | jq -r '.error.message // empty' 2>/dev/null)
  message="herdr could not open the workspace: ${reason:-$result}"
  return 1
}

# Act on the entry at line $2 of the listing for key $1: "" (Enter) goes
# into a directory (../ goes up), open opens a workspace there (at the
# current directory for ../ or a file), hidden toggles hidden entries.
# Returns 2 once a workspace was opened.
act() {
  entry=$(printf '%s\n' "$names" | sed -n "${2}p")
  path="$base/$entry"
  case "$1" in
    hidden)
      show_hidden=$((1 - show_hidden))
      ;;
    open)
      if [ "$2" != 1 ] && [ -d "$path" ]; then
        open_at "$path" && return 2
      else
        open_at "$dir" && return 2
      fi
      ;;
    *)
      if [ "$2" = 1 ]; then
        go_up
      elif [ -d "$path" ]; then
        enter_dir "$path"
      else
        message="$entry is a file; pick a directory."
      fi
      ;;
  esac
  return 0
}

# Show the listing and get one command; sets key and index, or fails when
# the user quits.
ask_fzf() {
  result=$(printf '%s\n' "$lines" | fzf --reverse --no-multi --no-sort --expect=ctrl-o,ctrl-t \
    --prompt="$dir: " \
    --header='Enter: go into (../ goes up)   ctrl-o: open a workspace here   ctrl-t: hidden files   Esc: quit')
  # 0 is a pick and 1 an empty match; 130 is Esc, and anything else is an
  # fzf error (a bad FZF_DEFAULT_OPTS, no terminal), which would reopen at once.
  case $? in
    0 | 1) ;;
    *) return 1 ;;
  esac
  case "$(printf '%s\n' "$result" | sed -n 1p)" in
    ctrl-o) key=open ;;
    ctrl-t) key=hidden ;;
    *) key='' ;;
  esac
  chosen=$(printf '%s\n' "$result" | sed -n 2p)
  index=$(printf '%s\n' "$lines" | CHOSEN=$chosen awk '$0 == ENVIRON["CHOSEN"] { print NR; exit }')
  [ -n "$index" ] || index=0
}

ask_menu() {
  printf '%s\n' "$lines" | awk '{ printf "%3d) %s\n", NR, $0 }'
  printf 'A number goes into that directory, - goes up, o opens a workspace here, o N at entry N, h shows or hides hidden files, q quits.\nChoice: '
  read -r answer || return 1
  key=''
  index=0
  case "$answer" in
    q | Q) return 1 ;;
    h | H) key=hidden ;;
    -) index=1 ;;
    o | O)
      key=open
      index=1
      ;;
    'o '* | 'O '*)
      key=open
      index=${answer#? }
      ;;
    *) index=$answer ;;
  esac
  case "$index" in
    '' | *[!0-9]*)
      message='Type a number, -, o, o N, h, or q.'
      key=skip
      ;;
  esac
}

browse() {
  start=${OMH_EXPLORER_CWD:-}
  if [ -z "$start" ] && command -v jq >/dev/null 2>&1; then
    start=$(printf '%s' "${HERDR_PLUGIN_CONTEXT_JSON:-}" | jq -r '.focused_pane_cwd // empty' 2>/dev/null)
  fi
  [ -n "$start" ] || start=${HOME:-/}
  dir=$(real_dir "$start") || dir=$(real_dir "${HOME:-/}") || dir=/
  show_hidden=0
  message=''
  while :; do
    base=${dir%/}
    list_dir
    render
    printf 'Directory: %s\n' "$dir"
    [ -z "$message" ] || printf '%s\n' "$message"
    message=''
    case "$skipped" in
      0) ;;
      1) printf '1 entry with a line break or tab in its name is not shown.\n' ;;
      *) printf '%s entries with a line break or tab in their names are not shown.\n' "$skipped" ;;
    esac
    if command -v fzf >/dev/null 2>&1; then
      ask_fzf || return 0
    else
      ask_menu || return 0
    fi
    [ "$key" != skip ] || continue
    if [ "$index" -lt 1 ] && [ "$key" != hidden ]; then
      continue
    fi
    act "$key" "$index"
    if [ $? -eq 2 ]; then
      return 0
    fi
  done
}

open_popup() {
  cwd=$(printf '%s' "${HERDR_PLUGIN_CONTEXT_JSON:-}" | jq -r '.focused_pane_cwd // empty' 2>/dev/null)
  set -- --plugin oh-my-herdr.workspace-explorer --entrypoint explorer
  [ -z "$cwd" ] || set -- "$@" --env "OMH_EXPLORER_CWD=$cwd"
  "$HERDR" plugin pane open "$@" 2>/dev/null 1>/dev/null ||
    printf 'workspace-explorer: could not open the popup\n' 1>&2
}

case "${1:-}" in
  browse) browse ;;
  open) open_popup ;;
  *) printf 'workspace-explorer: unknown mode %s; expected open or browse\n' "${1:-}" 1>&2 ;;
esac
exit 0
