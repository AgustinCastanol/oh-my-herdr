#!/bin/sh
# shellcheck shell=sh
#
# oh-my-herdr task-runner plugin.
#
#   task-runner.sh open        the "open" action: open the tasks popup
#   task-runner.sh popup       the popup: list the tasks of the focused pane's
#                              directory and run the chosen one in a new split
#                              below that pane
#   task-runner.sh list DIR    print the command of each task found in DIR
#
# Listing reads files only. package.json is parsed with jq, Makefile and
# justfile with awk; make, just, and package managers are never called, so
# opening the popup cannot run anything a project defines. Only the task the
# user picks runs, in its own pane.

HERDR=${HERDR_BIN_PATH:-herdr}

log() {
  printf 'task-runner: %s\n' "$*" >&2
}

# Print a word as-is when it is plain, or single-quoted for sh otherwise.
shell_word() {
  case "$1" in
    '' | *[!A-Za-z0-9_.:@/+=,-]*)
      printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
      ;;
    *) printf '%s' "$1" ;;
  esac
}

# package.json scripts, run with the package manager its lockfile implies.
package_tasks() {
  [ -f "$1/package.json" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    log "jq is not on PATH; skipping package.json"
    return 0
  fi
  if [ -f "$1/pnpm-lock.yaml" ]; then
    runner=pnpm
  elif [ -f "$1/yarn.lock" ]; then
    runner=yarn
  elif [ -f "$1/bun.lockb" ] || [ -f "$1/bun.lock" ]; then
    runner=bun
  else
    runner=npm
  fi
  jq -r '.scripts | objects | keys_unsorted[] | select(test("[\r\n]") | not)' \
    "$1/package.json" 2>/dev/null |
    while IFS= read -r script; do
      printf '%s run %s\n' "$runner" "$(shell_word "$script")"
    done
}

# Makefile targets, from a static read of the file make would use.
make_tasks() {
  for makefile in "$1/GNUmakefile" "$1/makefile" "$1/Makefile"; do
    [ -f "$makefile" ] && break
  done
  [ -f "$makefile" ] || return 0
  awk '
    /^define[ \t]/ { in_define = 1; next }
    /^endef/ { in_define = 0; next }
    in_define { next }
    /^[ \t]/ || /^#/ { next }              # recipe lines and comments
    /^[^:=]*[?+!]?=/ { next }              # VAR = x, ?=, +=, !=
    /^[^:]*::?=/ { next }                  # VAR := x, ::=, export VAR := x
    /^[^:]+:/ {
      names = $0
      sub(/:.*/, "", names)
      count = split(names, list, /[ \t]+/)
      for (i = 1; i <= count; i++) {
        name = list[i]
        # Skip special (.PHONY), pattern (%), and computed ($(...)) targets.
        if (name == "" || name ~ /^\./ || name ~ /[%$(){}]/ || seen[name]++) continue
        print name
      }
    }
  ' "$makefile" |
    while IFS= read -r target; do
      printf 'make %s\n' "$(shell_word "$target")"
    done
}

# justfile recipes, from a static read. just itself is not run, so nothing in
# the file (such as backtick expressions) can be evaluated while listing.
just_tasks() {
  for justfile in "$1/justfile" "$1/Justfile" "$1/.justfile"; do
    [ -f "$justfile" ] && break
  done
  [ -f "$justfile" ] || return 0
  awk '
    /^[ \t]/ || /^#/ || /^$/ { next }      # recipe bodies, comments, blanks
    /^\[/ { if ($0 ~ /private/) private = 1; next }
    /^(alias|set|export|import|mod)[ \t]/ { private = 0; next }
    /^@?[A-Za-z_][A-Za-z0-9_-]*([ \t][^:]*)?:([^=]|$)/ {
      name = $0
      sub(/^@/, "", name)
      sub(/[ \t:].*/, "", name)
      if (!private && name !~ /^_/ && !seen[name]++) print name
      private = 0
      next
    }
    { private = 0 }                        # assignments and anything else
  ' "$justfile" |
    while IFS= read -r recipe; do
      printf 'just %s\n' "$(shell_word "$recipe")"
    done
}

list_tasks() {
  package_tasks "$1"
  make_tasks "$1"
  just_tasks "$1"
}

wait_for_enter() {
  printf 'Press Enter to close.'
  read -r _ || true
}

# Let the user pick one line of $1; print it, or fail when cancelled. The
# numbered menu goes to stderr because stdout carries the choice.
choose_task() {
  if command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "$1" | fzf --prompt='task> ' --reverse --no-multi \
      --header="Tasks in $2 (Enter runs, Esc cancels)"
    return
  fi
  {
    printf 'Tasks in %s:\n' "$2"
    printf '%s\n' "$1" | awk '{ printf "%3d) %s\n", NR, $0 }'
    printf 'Run which task? Type its number and press Enter (Enter alone cancels): '
  } >&2
  read -r answer || return 1
  case "$answer" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$answer" -ge 1 ] || return 1
  printf '%s\n' "$1" | sed -n "${answer}p"
}

# Print the id of every pane, one per line; fail when herdr cannot list them.
pane_ids() {
  pane_list=$("$HERDR" pane list 2>/dev/null) || return 1
  printf '%s' "$pane_list" | jq -r '.result.panes[].pane_id' 2>/dev/null
}

# Best-effort undo of a split that succeeded but whose new pane id could not
# be read. A pane is new when it is in workspace $2 (an id prefix such as
# "w1:") and not in the list $1 taken before the split. Close it only when
# exactly one appeared; otherwise say which panes may need closing.
close_new_panes() {
  panes_after=$(pane_ids) || return 0
  new_panes=''
  for pane in $panes_after; do
    case "$pane" in
      "$2"*) ;;
      *) continue ;;
    esac
    case "
$1
" in
      *"
$pane
"*) continue ;;
    esac
    new_panes="${new_panes:+$new_panes }$pane"
  done
  case "$new_panes" in
    '') ;;
    *' '*)
      # More than one new pane: one may be the user's own, so close none.
      printf 'Panes %s appeared during the split; task-runner closed none of them. Close the one it opened if it is still there.\n' "$new_panes"
      ;;
    *)
      "$HERDR" pane close "$new_panes" >/dev/null 2>&1 &&
        log "closed pane $new_panes left by a split whose result could not be read"
      ;;
  esac
}

popup() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'task-runner needs jq, which is not on PATH.\n'
    wait_for_enter
    return 0
  fi
  context=${HERDR_PLUGIN_CONTEXT_JSON:-}
  origin=$(printf '%s' "$context" | jq -r '.focused_pane_id // empty' 2>/dev/null)
  dir=$(printf '%s' "$context" | jq -r '.focused_pane_cwd // empty' 2>/dev/null)
  if [ -z "$origin" ] || [ -z "$dir" ] || [ ! -d "$dir" ]; then
    printf 'task-runner: there is no focused pane with a working directory to run tasks in.\n'
    wait_for_enter
    return 0
  fi

  tasks=$(list_tasks "$dir")
  if [ -z "$tasks" ]; then
    printf 'No tasks found in %s\n' "$dir"
    printf 'task-runner looks for package.json scripts, Makefile targets, and justfile recipes.\n'
    wait_for_enter
    return 0
  fi

  task=$(choose_task "$tasks" "$dir") || return 0
  [ -n "$task" ] || return 0

  # Remember the panes that exist now, to undo a split whose result is
  # unreadable (see close_new_panes).
  panes_known=0
  ! panes_before=$(pane_ids) || panes_known=1
  # A split below keeps the full width for build and test output.
  split_ok=0
  ! split_output=$("$HERDR" pane split "$origin" --direction down --cwd "$dir" 2>/dev/null) ||
    split_ok=1
  new_pane=$(printf '%s' "$split_output" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  if [ -z "$new_pane" ]; then
    if [ "$split_ok" = 1 ] && [ "$panes_known" = 1 ]; then
      close_new_panes "$panes_before" "${origin%%:*}:"
    fi
    printf 'Could not open a split next to pane %s.\n' "$origin"
    wait_for_enter
    return 0
  fi
  if ! "$HERDR" pane run "$new_pane" "$task" >/dev/null 2>&1; then
    printf 'Could not start "%s" in pane %s.\n' "$task" "$new_pane"
    wait_for_enter
  fi
}

open_popup() {
  "$HERDR" plugin pane open --plugin oh-my-herdr.task-runner --entrypoint tasks >/dev/null 2>&1 ||
    log "could not open the tasks popup"
}

case "${1:-}" in
  list)
    if [ -d "${2:-}" ]; then
      list_tasks "$2"
    else
      log "list needs a directory"
    fi
    ;;
  popup) popup ;;
  open) open_popup ;;
  *) log "unknown mode '${1:-}'; expected open, popup, or list DIR" ;;
esac
exit 0
