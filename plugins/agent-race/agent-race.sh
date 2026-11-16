#!/bin/sh
# shellcheck shell=sh
#
# oh-my-herdr agent-race plugin: give one task to several agents at once,
# each in its own git worktree, then compare what they did and clean up.
#
#   agent-race.sh open-start | open-compare | open-cleanup
#                            actions: open that popup for the focused pane
#   agent-race.sh start      popup: pick the task and 2 to 4 agents, confirm,
#                            create the worktrees, and start the agents
#   agent-race.sh compare    popup: each agent's state and changes
#   agent-race.sh cleanup    popup: remove a race's worktrees and branches
#   agent-race.sh deliver RACE KIND
#                            started by "start" in the background: start one
#                            agent, wait until it is ready, send it the task
#
# Safety:
# - Nothing is created or sent before you confirm the summary.
# - Agents start with `herdr agent start NAME --kind KIND --pane PANE` and
#   nothing else, so each keeps its own approval settings.
# - The repository is found with `git rev-parse` only. Worktrees are created
#   with `git worktree add` with hooks and fsmonitor turned off (herdr's own
#   `worktree create` runs both) and then opened in herdr. Diffs, status
#   checks, and removals run with hooks, fsmonitor, external diff tools, and
#   textconv turned off; checkout and clean filters still run, as in any use
#   of git in your own repository.
# - Only branches this plugin created (race/<race>-<agent>) are deleted, and
#   never the base branch. A worktree with changes, or a branch with commits
#   that are not merged, is removed only after a second confirmation.
#
# A race lives in $HERDR_PLUGIN_STATE_DIR/races/<race>: "task" (the task
# text), "race" (repo, base, base_branch, prompt lines), "agents" (one
# tab-separated line per agent: kind, branch, worktree, workspace, pane,
# name), and <kind>.status with what happened to the task.

HERDR=${HERDR_BIN_PATH:-herdr}
MIN_AGENTS=2
MAX_AGENTS=4
MAX_RACES=3
# herdr agent names: a lowercase letter, then lowercase letters, digits, '-'
# or '_', at most this many characters.
AGENT_NAME_MAX=32
# How long `agent start` waits for an agent to be ready, and how long a
# delivery then waits for an agent held at a startup prompt (milliseconds).
START_TIMEOUT_MS=60000
READY_TIMEOUT_MS=600000
# The kinds herdr 0.9.5 can start, used when `herdr agent start --help` does
# not list them.
KNOWN_KINDS='pi claude codex gemini cursor devin agy cline omp mastracode opencode copilot kimi kiro droid amp grok hermes kilo qodercli qwen letta maki muse'
case "$0" in
  */*) SCRIPT=$0 ;;
  *) SCRIPT=./$0 ;;
esac
HANDOFF=${OMH_AGENT_HANDOFF:-${SCRIPT%/*}/../agent-handoff/agent-handoff.sh}
TAB=$(printf '\t')
NL='
'

log() {
  printf 'agent-race: %s\n' "$*" >&2
}

wait_for_enter() {
  printf 'Press Enter to close.'
  read -r _ || true
}

# git with nothing the repository configures to run on its own: no hooks
# and no fsmonitor.
safe_git() {
  git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
}

is_error() {
  printf '%s' "$1" | jq -e '.error' >/dev/null 2>&1
}

error_text() {
  reason=$(printf '%s' "$1" | jq -r '.error.message // empty' 2>/dev/null)
  printf '%s' "${reason:-$1}" | head -n 1
}

# Quote $1 for a POSIX shell command line.
shquote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Print a branch-safe name of at most $2 characters from the first line of
# $1, cut after a whole word when it can be, or "race".
slugify() {
  slug=$(printf '%s\n' "$1" | head -n 1 | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' |
    sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//' |
    awk -v max="$2" '{
      if (length($0) > max) {
        cut = substr($0, 1, max)
        if (substr($0, max + 1, 1) != "-" && match(cut, /.*-/)) cut = substr(cut, 1, RLENGTH - 1)
        $0 = cut
      }
      print
    }' | sed 's/-$//')
  printf '%s\n' "${slug:-race}"
}

# Let the user pick one line of $3 ($1 names it for fzf, $2 is the question);
# print it, or fail when cancelled. The menu goes to stderr.
choose_line() {
  if command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "$3" | fzf --prompt="$1> " --reverse --no-multi --header="$2 (Enter picks, Esc cancels)"
    return
  fi
  {
    printf '%s\n' "$2"
    printf '%s\n' "$3" | awk '{ printf "%3d) %s\n", NR, $0 }'
    printf 'Type its number and press Enter (Enter alone cancels): '
  } >&2
  read -r answer || return 1
  case "$answer" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$3" | sed -n "${answer}p"
}

# Let the user pick several lines of $2 ($1 is the question); print them.
# Fails with 1 when cancelled and 2 when the answer names no such line.
choose_many() {
  if command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "$2" | fzf -m --prompt='agents> ' --reverse --header="$1 (Tab marks, Enter picks)"
    return
  fi
  {
    printf '%s\n' "$1"
    printf '%s\n' "$2" | awk '{ printf "%3d) %s\n", NR, $0 }'
    printf 'Type their numbers separated by spaces (Enter alone cancels): '
  } >&2
  read -r answer || return 1
  [ -n "$answer" ] || return 1
  chosen=''
  for number in $(printf '%s' "$answer" | tr ',' ' '); do
    case "$number" in
      '' | *[!0-9]*) return 2 ;;
    esac
    line=$(printf '%s\n' "$2" | sed -n "${number}p")
    [ -n "$line" ] || return 2
    case "$NL$chosen$NL" in
      *"$NL$line$NL"*) continue ;;
    esac
    chosen=${chosen:+$chosen$NL}$line
  done
  printf '%s\n' "$chosen"
}

# Set origin and cwd: from the action that opened this popup, else from the
# popup's own context, asking herdr for the cwd only when neither has it.
find_origin() {
  if [ -n "${OMH_RACE_PANE:-}" ]; then
    origin=$OMH_RACE_PANE
    cwd=${OMH_RACE_CWD:-}
  else
    context=${HERDR_PLUGIN_CONTEXT_JSON:-}
    origin=$(printf '%s' "$context" | jq -r '.focused_pane_id // empty' 2>/dev/null)
    cwd=$(printf '%s' "$context" | jq -r '.focused_pane_cwd // empty' 2>/dev/null)
  fi
  if [ -z "$cwd" ] && [ -n "$origin" ]; then
    cwd=$("$HERDR" pane get "$origin" 2>/dev/null |
      jq -r '.result.pane | (.foreground_cwd // .cwd) // empty' 2>/dev/null)
  fi
}

need_tools() {
  for tool in jq git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      printf 'Agent race needs %s, which is not on PATH.\n' "$tool"
      wait_for_enter
      return 1
    fi
  done
}

# Print the agent kinds herdr can start whose command is on PATH.
available_kinds() {
  kinds=$("$HERDR" agent start --help 2>/dev/null |
    sed -n 's/.*\[possible values: \(.*\)\].*/\1/p' | head -n 1 | tr -d ',')
  [ -n "$kinds" ] || kinds=$KNOWN_KINDS
  for kind in $kinds; do
    case "$kind" in
      *[!a-z0-9-]*) continue ;;
    esac
    if command -v "$kind" >/dev/null 2>&1; then
      printf '%s\n' "$kind"
    fi
  done
}

race_count() {
  count=0
  for dir in "$RACES"/*; do
    [ -d "$dir" ] && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

# Read key $2 from race file $1/race.
race_value() {
  sed -n "s/^$2=//p" "$1/race" 2>/dev/null | head -n 1
}

# Set entries to the saved prompts that attach no pane output, as
# "TITLE  (FILE)<tab>PATH" lines, from the agent-handoff plugin.
saved_prompts() {
  entries=''
  [ -f "$HANDOFF" ] || return 0
  all=$(sh "$HANDOFF" list-prompts 2>/dev/null) || return 0
  while IFS=$TAB read -r prompt_title prompt_path; do
    [ -f "$prompt_path" ] || continue
    grep -F -q '{{context}}' "$prompt_path" && continue
    entries=${entries:+$entries$NL}$prompt_title$TAB$prompt_path
  done <<EOF
$all
EOF
}

start_popup() {
  need_tools || return 0
  find_origin
  if [ -z "$cwd" ] || ! repo=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || [ -z "$repo" ]; then
    printf 'Agent race needs a git repository: %s is not inside one.\n' "${cwd:-this pane}"
    wait_for_enter
    return 0
  fi
  if ! base=$(git -C "$repo" rev-parse --verify -q 'HEAD^{commit}'); then
    printf 'Agent race needs a commit to start from: %s has none yet.\n' "$repo"
    wait_for_enter
    return 0
  fi
  base_branch=$(git -C "$repo" symbolic-ref --short -q HEAD) || base_branch=''
  if [ "$(race_count)" -ge "$MAX_RACES" ]; then
    printf 'There are already %s races. Clean one up first (prefix+ctrl+x).\n' "$MAX_RACES"
    wait_for_enter
    return 0
  fi
  kinds=$(available_kinds)
  if [ "$(printf '%s' "$kinds" | awk 'END { print NR }')" -lt "$MIN_AGENTS" ]; then
    printf 'Agent race needs at least %s agents whose command is on PATH; found: %s.\n' \
      "$MIN_AGENTS" "$(printf '%s' "${kinds:-none}" | tr '\n' ' ')"
    wait_for_enter
    return 0
  fi

  printf 'The task for the agents (one line), or press Enter to pick a saved prompt:\n> '
  read -r task || task=''
  prompt=0
  name_from=$task
  if [ -z "$task" ]; then
    saved_prompts
    if [ -z "$entries" ]; then
      printf 'No saved prompt without {{context}} was found; type a task instead.\n'
      wait_for_enter
      return 0
    fi
    titles=$(printf '%s\n' "$entries" | awk -F '\t' '{ print $1 }')
    title=$(choose_line prompt 'Which prompt?' "$titles") || return 0
    [ -n "$title" ] || return 0
    prompt_path=$(printf '%s\n' "$entries" | CHOICE=$title awk -F '\t' '$1 == ENVIRON["CHOICE"] { print $2; exit }')
    [ -f "$prompt_path" ] || return 0
    task=$(cat "$prompt_path")
    prompt=1
    name_from=${title%  (*}
  fi

  picked=$(choose_many "Pick $MIN_AGENTS to $MAX_AGENTS agents to race:" "$kinds")
  case $? in
    0) ;;
    1)
      printf 'Nothing was started.\n'
      return 0
      ;;
    *) picked='' ;;
  esac
  picked_count=$(printf '%s' "$picked" | awk 'NF { n++ } END { print n + 0 }')
  if [ "$picked_count" -lt "$MIN_AGENTS" ] || [ "$picked_count" -gt "$MAX_AGENTS" ]; then
    printf 'Pick %s to %s agents; nothing was started.\n' "$MIN_AGENTS" "$MAX_AGENTS"
    wait_for_enter
    return 0
  fi

  # A race name, branches, and worktrees nobody uses yet. herdr agent names
  # ("race-<race>-<kind>") have at most AGENT_NAME_MAX characters, so the
  # name leaves room for the longest picked kind and a "-N" suffix.
  worktree_root="${HOME:?}/.herdr/worktrees/${repo##*/}"
  longest=$(printf '%s\n' "$picked" | awk '{ if (length($0) > n) n = length($0) } END { print n + 0 }')
  slug_max=$((AGENT_NAME_MAX - 6 - longest - 3))
  [ "$slug_max" -ge 4 ] || slug_max=4
  slug=$(slugify "$name_from" "$slug_max")
  race=$slug
  number=1
  while :; do
    taken=0
    [ ! -e "$RACES/$race" ] || taken=1
    for kind in $picked; do
      if git -C "$repo" rev-parse --verify -q "refs/heads/race/$race-$kind" >/dev/null ||
        [ -e "$worktree_root/race-$race-$kind" ]; then
        taken=1
      fi
    done
    [ "$taken" = 1 ] || break
    number=$((number + 1))
    race=$slug-$number
  done

  printf '\nTask: %s\n' "$(printf '%s\n' "$task" | head -n 1)"
  more=$(printf '%s\n' "$task" | awk 'END { print NR - 1 }')
  [ "$more" -eq 0 ] || printf '      (and %s more lines)\n' "$more"
  printf 'Repository: %s\n' "$repo"
  printf 'Base: %.7s (%s)\n' "$base" "${base_branch:-detached HEAD}"
  printf 'Agents, their branches and worktrees:\n'
  for kind in $picked; do
    printf '  %s  %s  %s\n' "$kind" "race/$race-$kind" "$worktree_root/race-$race-$kind"
  done
  printf 'Each agent starts with its own approval settings and gets the task once it is ready.\n'
  printf 'Start the race? [y/N] '
  read -r confirm || confirm=''
  case "$confirm" in
    y | Y | yes | Yes | YES) ;;
    *)
      printf 'Nothing was started.\n'
      wait_for_enter
      return 0
      ;;
  esac

  dir="$RACES/$race"
  mkdir -p "$dir" "$worktree_root" || return 0
  printf '%s\n' "$task" >"$dir/task"
  printf 'repo=%s\nbase=%s\nbase_branch=%s\nprompt=%s\n' "$repo" "$base" "$base_branch" "$prompt" >"$dir/race"
  : >"$dir/agents"
  for kind in $picked; do
    start_agent "$kind"
  done
  if [ ! -s "$dir/agents" ]; then
    rm -rf "$dir"
    printf 'No agent was started.\n'
  else
    printf 'Each agent gets the task once it is ready. Compare with prefix+ctrl+d; clean up with prefix+ctrl+x.\n'
  fi
  wait_for_enter
}

# Create and open the worktree for agent kind $1 of the race in $dir, then
# start its delivery in the background. A failure is reported and undone.
start_agent() {
  kind=$1
  branch=race/$race-$kind
  label=race-$race-$kind
  worktree=$worktree_root/$label
  if ! out=$(safe_git -C "$repo" worktree add -q -b "$branch" "$worktree" "$base" 2>&1); then
    printf '%s: could not create the worktree: %s\n' "$kind" "$(printf '%s' "$out" | head -n 1)"
    return 0
  fi
  if ! opened=$("$HERDR" worktree open --cwd "$repo" --path "$worktree" --label "$label" --no-focus 2>&1) ||
    is_error "$opened" ||
    ! pane=$(printf '%s' "$opened" | jq -er '.result.root_pane.pane_id' 2>/dev/null); then
    printf '%s: could not open the worktree in herdr: %s\n' "$kind" "$(error_text "$opened")"
    safe_git -C "$repo" worktree remove --force "$worktree" >/dev/null 2>&1
    safe_git -C "$repo" branch -D "$branch" >/dev/null 2>&1
    return 0
  fi
  # Tab-separated fields must not be empty ("-" stands for none): read
  # would join the tabs around an empty one.
  workspace=$(printf '%s' "$opened" | jq -r '.result.workspace.workspace_id // "-"' 2>/dev/null)
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$branch" "$worktree" "$workspace" "$pane" "$label" >>"$dir/agents"
  printf 'starting\n' >"$dir/$kind.status"
  nohup sh "$SCRIPT" deliver "$race" "$kind" </dev/null >/dev/null 2>>"$dir/$kind.log" &
  printf '%s: starting in %s (%s)\n' "$kind" "$label" "$pane"
}

# Start agent kind $2 of race $1, wait until it is ready, and send the task.
deliver() {
  dir="$RACES/$1"
  kind=$2
  line=$(KIND=$kind awk -F '\t' '$1 == ENVIRON["KIND"] { print; exit }' "$dir/agents" 2>/dev/null)
  [ -n "$line" ] || return 0
  IFS=$TAB read -r _ _ worktree _ pane name <<EOF
$line
EOF
  if ! result=$("$HERDR" agent start "$name" --kind "$kind" --pane "$pane" --timeout "$START_TIMEOUT_MS" 2>&1) ||
    is_error "$result"; then
    if [ "$(printf '%s' "$result" | jq -r '.error.code // empty' 2>/dev/null)" != agent_not_ready ]; then
      printf 'could not start: %s\n' "$(error_text "$result")" >"$dir/$kind.status"
      return 0
    fi
    printf 'waiting for you: answer its startup prompt in pane %s; the task follows once it is ready\n' "$pane" >"$dir/$kind.status"
    if ! result=$("$HERDR" agent wait "$name" --until idle --timeout "$READY_TIMEOUT_MS" 2>&1) ||
      is_error "$result"; then
      printf 'not ready within %s minutes; task not sent\n' "$((READY_TIMEOUT_MS / 60000))" >"$dir/$kind.status"
      return 0
    fi
  fi
  if [ "$(race_value "$dir" prompt)" = 1 ] && [ -f "$HANDOFF" ]; then
    text=$(OMH_CWD=$worktree OMH_CONTEXT='' sh "$HANDOFF" expand-prompt "$dir/task")
  else
    text=$(cat "$dir/task")
  fi
  if result=$("$HERDR" agent prompt "$name" "$text" 2>&1) && ! is_error "$result"; then
    printf 'task sent\n' >"$dir/$kind.status"
  else
    printf 'could not send the task: %s\n' "$(error_text "$result")" >"$dir/$kind.status"
  fi
}

# Set race and dir to the race the user picks (the only one, if just one).
pick_race() {
  races=''
  for dir in "$RACES"/*; do
    [ -f "$dir/race" ] || continue
    races="${races:+$races$NL}${dir##*/}  $(head -n 1 "$dir/task" 2>/dev/null)"
  done
  if [ -z "$races" ]; then
    printf 'No race yet. Start one with prefix+ctrl+r.\n'
    wait_for_enter
    return 1
  fi
  if [ "$(printf '%s\n' "$races" | awk 'END { print NR }')" = 1 ]; then
    choice=$races
  else
    choice=$(choose_line race 'Which race?' "$races") || return 1
  fi
  race=${choice%%  *}
  dir="$RACES/$race"
  [ -f "$dir/race" ]
}

compare_popup() {
  need_tools || return 0
  find_origin
  pick_race || return 0
  base=$(race_value "$dir" base)
  printf 'Race %s: %s\n' "$race" "$(head -n 1 "$dir/task")"
  printf 'Changes are against the base commit %.7s.\n' "$base"
  number=0
  while IFS=$TAB read -r kind branch worktree _ _ name; do
    [ -n "$kind" ] || continue
    number=$((number + 1))
    printf '\n%s) %s  %s\n' "$number" "$kind" "$branch"
    state=$("$HERDR" agent get "$name" </dev/null 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
    printf '   agent: %s; %s\n' "${state:-not running}" "$(cat "$dir/$kind.status" 2>/dev/null)"
    if [ ! -d "$worktree" ]; then
      printf '   worktree removed\n'
      continue
    fi
    stat=$(safe_git -C "$worktree" diff --stat --no-ext-diff --no-textconv "$base" </dev/null 2>&1)
    untracked=$(safe_git -C "$worktree" ls-files --others --exclude-standard </dev/null 2>/dev/null | awk 'END { print NR }')
    if [ -z "$stat" ] && [ "$untracked" = 0 ]; then
      printf '   no changes\n'
      continue
    fi
    [ -z "$stat" ] || printf '%s\n' "$stat" | sed 's/^/  /'
    case "$untracked" in
      0) ;;
      1) printf '   1 untracked file\n' ;;
      *) printf '   %s untracked files\n' "$untracked" ;;
    esac
  done <"$dir/agents"

  installed=$("$HERDR" plugin list --json 2>/dev/null | tr -d ' \t\r\n')
  case "$installed" in
    *'"plugin_id":"persiyanov.reviewr"'*)
      printf '\npersiyanov.reviewr is installed: open an agent'"'"'s workspace to review its changes there.\n'
      ;;
  esac

  printf '\nType an agent'"'"'s number to open its full diff in a new pane, or press Enter to close: '
  read -r answer || answer=''
  case "$answer" in
    '' | *[!0-9]*) return 0 ;;
  esac
  line=$(sed -n "${answer}p" "$dir/agents")
  [ -n "$line" ] || return 0
  IFS=$TAB read -r _ _ worktree _ _ _ <<EOF
$line
EOF
  [ -d "$worktree" ] && [ -n "$origin" ] || return 0
  new_pane=$("$HERDR" pane split "$origin" --direction down 2>/dev/null |
    jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  [ -n "$new_pane" ] || return 0
  "$HERDR" pane run "$new_pane" \
    "git -C $(shquote "$worktree") -c core.fsmonitor=false -c core.hooksPath=/dev/null diff --no-ext-diff --no-textconv $base" \
    >/dev/null 2>&1
}

# Close the herdr workspace $1 of race agent $2 (its label), but only while
# it still has that label: workspace ids are reused after herdr restarts.
close_workspace() {
  [ -n "$1" ] && [ "$1" != - ] || return 0
  current=$("$HERDR" workspace get "$1" </dev/null 2>/dev/null | jq -r '.result.workspace.label // empty' 2>/dev/null)
  [ "$current" != "$2" ] || "$HERDR" workspace close "$1" </dev/null >/dev/null 2>&1
}

cleanup_popup() {
  need_tools || return 0
  pick_race || return 0
  repo=$(race_value "$dir" repo)
  base_branch=$(race_value "$dir" base_branch)
  printf 'Race %s: %s\n' "$race" "$(head -n 1 "$dir/task")"
  dirty=''
  while IFS=$TAB read -r kind branch worktree _ _ label; do
    [ -n "$kind" ] || continue
    if [ ! -d "$worktree" ]; then
      mark='already removed'
    elif [ -n "$(safe_git -C "$worktree" status --porcelain </dev/null 2>/dev/null)" ]; then
      mark=changes
      dirty=${dirty:+$dirty }$kind
    else
      mark=clean
    fi
    printf '  %s  [%s]  %s\n' "$label" "$mark" "$branch"
  done <"$dir/agents"
  printf 'Type the race name (%s) to remove these worktrees, or press Enter to keep them: ' "$race"
  read -r answer || answer=''
  if [ "$answer" != "$race" ] && [ "$answer" != yes ]; then
    printf 'Nothing was removed.\n'
    wait_for_enter
    return 0
  fi

  discard=0
  if [ -n "$dirty" ]; then
    printf 'These worktrees have changes that would be lost: %s\n' "$dirty"
    printf 'Type discard to remove them anyway, or press Enter to keep them: '
    read -r answer || answer=''
    [ "$answer" != discard ] || discard=1
  fi

  removed_branches=''
  : >"$dir/agents.left"
  while IFS=$TAB read -r kind branch worktree workspace pane label; do
    [ -n "$kind" ] || continue
    if [ -d "$worktree" ]; then
      case " $dirty " in
        *" $kind "*)
          if [ "$discard" != 1 ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$branch" "$worktree" "$workspace" "$pane" "$label" >>"$dir/agents.left"
            printf '%s: kept, it has changes\n' "$kind"
            continue
          fi
          force=--force
          ;;
        *) force='' ;;
      esac
      close_workspace "$workspace" "$label"
      # shellcheck disable=SC2086
      if ! out=$(safe_git -C "$repo" worktree remove $force "$worktree" </dev/null 2>&1); then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$branch" "$worktree" "$workspace" "$pane" "$label" >>"$dir/agents.left"
        printf '%s: could not remove the worktree: %s\n' "$kind" "$(printf '%s' "$out" | head -n 1)"
        continue
      fi
      printf '%s: worktree removed\n' "$kind"
    fi
    removed_branches=${removed_branches:+$removed_branches }$branch
  done <"$dir/agents"

  # Branches: only this race's own, never the base branch. Merged ones go
  # quietly; the others only after "delete".
  unmerged=''
  for branch in $removed_branches; do
    case "$branch" in
      "race/$race-"*) ;;
      *) continue ;;
    esac
    [ "$branch" != "$base_branch" ] || continue
    safe_git -C "$repo" rev-parse --verify -q "refs/heads/$branch" >/dev/null || continue
    safe_git -C "$repo" branch -d "$branch" >/dev/null 2>&1 || unmerged=${unmerged:+$unmerged }$branch
  done
  if [ -n "$unmerged" ]; then
    printf 'These race branches have commits that are not merged: %s\n' "$unmerged"
    printf 'Type delete to delete them too, or press Enter to keep them: '
    read -r answer || answer=''
    if [ "$answer" = delete ]; then
      for branch in $unmerged; do
        safe_git -C "$repo" branch -D "$branch" >/dev/null 2>&1 && printf '%s: deleted\n' "$branch"
      done
    else
      printf 'Kept: %s\n' "$unmerged"
    fi
  fi

  if [ -s "$dir/agents.left" ]; then
    mv "$dir/agents.left" "$dir/agents"
  else
    rm -rf "$dir"
    printf 'Race %s is cleaned up.\n' "$race"
  fi
  wait_for_enter
}

# Open popup $1 for the pane the action ran on, passing the pane and its cwd.
open_popup() {
  context=${HERDR_PLUGIN_CONTEXT_JSON:-}
  origin=$(printf '%s' "$context" | jq -r '.focused_pane_id // empty' 2>/dev/null)
  cwd=''
  if [ -n "$origin" ]; then
    cwd=$(printf '%s' "$context" | jq -r '.focused_pane_cwd // empty' 2>/dev/null)
  else
    origin=${HERDR_PANE_ID:-}
  fi
  set -- --plugin oh-my-herdr.agent-race --entrypoint "$1"
  [ -z "$origin" ] || set -- "$@" --env "OMH_RACE_PANE=$origin"
  [ -z "$cwd" ] || set -- "$@" --env "OMH_RACE_CWD=$cwd"
  "$HERDR" plugin pane open "$@" >/dev/null 2>&1 || log "could not open the popup"
}

if [ -z "${HERDR_PLUGIN_STATE_DIR:-}" ]; then
  log "HERDR_PLUGIN_STATE_DIR is not set; nothing to do"
  exit 0
fi
RACES="$HERDR_PLUGIN_STATE_DIR/races"
mkdir -p "$RACES" 2>/dev/null

case "${1:-}" in
  start) start_popup ;;
  compare) compare_popup ;;
  cleanup) cleanup_popup ;;
  open-start) open_popup start ;;
  open-compare) open_popup compare ;;
  open-cleanup) open_popup cleanup ;;
  deliver)
    case "${2:-}${3:-}" in
      '' | *[!A-Za-z0-9-]*) log "deliver needs a race and an agent kind" ;;
      *) deliver "$2" "$3" ;;
    esac
    ;;
  *) log "unknown mode '${1:-}'; expected start, compare, cleanup, open-start, open-compare, open-cleanup, or deliver" ;;
esac
exit 0
