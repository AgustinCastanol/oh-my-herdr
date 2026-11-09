#!/bin/sh
# shellcheck shell=sh
#
# oh-my-herdr installer: an opinionated setup for the herdr TUI.
#
#   curl -fsSL https://raw.githubusercontent.com/AgustinCastanol/oh-my-herdr/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/AgustinCastanol/oh-my-herdr/main/install.sh | sh -s -- --modules git,scratch
#   sh install.sh [--modules LIST|all|none] [--dry-run] [--uninstall] [--yes] [--help]
#
# Nothing runs until main() at the very end, so a partially downloaded
# script does nothing.

set -eu

MIN_HERDR_VERSION=0.9.0
DEFAULT_REPO=https://github.com/AgustinCastanol/oh-my-herdr.git
INSTALLER_URL=https://raw.githubusercontent.com/AgustinCastanol/oh-my-herdr/main/install.sh
HERDR_INSTALL_URL=https://herdr.dev/install.sh
# Modules installed when --modules is not given and no earlier choice is
# recorded. Each one is skipped when the tool named in its "# Requires:
# <tool> on PATH" header line is missing.
DEFAULT_MODULES="git scratch"
# First line of every config this script writes. It is how a config is
# recognised as managed (regenerate it) rather than the user's (back it up).
MARKER="# Managed by oh-my-herdr."
BACKUP_SUFFIX=.pre-oh-my-herdr
STATE_NAME=.install-state

usage() {
  cat <<EOF
oh-my-herdr installer

Usage:
  sh install.sh [options]
  curl -fsSL $INSTALLER_URL | sh -s -- [options]

Options:
  --modules LIST   Modules to enable: a comma-separated list, "all", or
                   "none". Default: the modules chosen last time, or
                   "$DEFAULT_MODULES" (each only if its tool is installed).
  --dry-run        Print what would happen and change nothing.
  --uninstall      Unlink plugins, restore your previous herdr config,
                   and remove the oh-my-herdr directory.
  -y, --yes        Do not ask for confirmation (needed for --uninstall
                   when stdin is not a terminal).
  -h, --help       Show this help.

Environment:
  HERDR_CONFIG_PATH  herdr config to manage (default ~/.config/herdr/config.toml)
  OMH_DIR            oh-my-herdr checkout (default ~/.local/share/oh-my-herdr)
  OMH_REPO           git URL to clone (default $DEFAULT_REPO)
  OMH_SOURCE         install from this local checkout instead of cloning
EOF
}

# --- Output ---------------------------------------------------------------

setup_colors() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_BOLD=$(printf '\033[1m')
    C_GREEN=$(printf '\033[32m')
    C_YELLOW=$(printf '\033[33m')
    C_RED=$(printf '\033[31m')
    C_RESET=$(printf '\033[0m')
  else
    C_BOLD='' C_GREEN='' C_YELLOW='' C_RED='' C_RESET=''
  fi
}

say() { printf '%s==>%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() {
  printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}

# Run a command, or only print it when --dry-run is set.
act() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '%s[dry run]%s %s\n' "$C_BOLD" "$C_RESET" "$*"
  else
    "$@"
  fi
}

# Print a step that --dry-run would take but that act() cannot express.
plan() { printf '%s[dry run]%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }

# --- Arguments and paths --------------------------------------------------

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --modules)
        [ "$#" -ge 2 ] || die "--modules needs a value: a comma-separated list, all, or none."
        MODULES_ARG=$2
        MODULES_SET=1
        shift 2
        ;;
      --modules=*)
        MODULES_ARG=${1#--modules=}
        MODULES_SET=1
        shift
        ;;
      --dry-run) DRY_RUN=1 && shift ;;
      --uninstall) MODE=uninstall && shift ;;
      -y | --yes) ASSUME_YES=1 && shift ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
  done
  if [ "$MODULES_SET" = 1 ] && [ -z "$MODULES_ARG" ]; then
    die "--modules needs a value: a comma-separated list, all, or none."
  fi
  if [ "$MODE" = uninstall ] && [ "$MODULES_SET" = 1 ]; then
    die "--modules cannot be combined with --uninstall."
  fi
}

resolve_paths() {
  : "${HOME:?HOME is not set}"
  CONFIG_FILE=${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}
  BACKUP_FILE=$CONFIG_FILE$BACKUP_SUFFIX
  OMH_DIR=${OMH_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/oh-my-herdr}
  STATE_FILE=$OMH_DIR/$STATE_NAME
  LOCAL_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-herdr/local.toml
  REPO_URL=${OMH_REPO:-$DEFAULT_REPO}
}

# Print the value of KEY from the state file of an earlier install.
state_get() {
  [ -f "$STATE_FILE" ] || return 0
  sed -n "s/^$1=//p" "$STATE_FILE" | head -n 1
}

exists() { [ -e "$1" ] || [ -L "$1" ]; }

# True when the file was written by this script.
is_managed() {
  [ -f "$1" ] || return 1
  case "$(head -n 1 "$1")" in
    "$MARKER"*) return 0 ;;
  esac
  return 1
}

# True when $1 is one of the space-separated words in $2.
has_word() {
  case " $2 " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# --- Checks ---------------------------------------------------------------

preflight() {
  os=$(uname -s)
  case "$os" in
    Linux | Darwin) ;;
    *) die "oh-my-herdr supports Linux and macOS only (this system is $os)." ;;
  esac
  if [ "$MODE" = install ] && ! command -v git >/dev/null 2>&1; then
    die "git is required. Install git, then run this again."
  fi
}

# Refuse early, before anything is installed or downloaded, when the existing
# config would need a backup but a backup is already there.
check_config_conflict() {
  if exists "$CONFIG_FILE" && ! is_managed "$CONFIG_FILE" && exists "$BACKUP_FILE"; then
    die "$CONFIG_FILE is not managed by oh-my-herdr, and a backup already exists at $BACKUP_FILE.
  The backup is never overwritten. Move one of the two files away, then run this again."
  fi
}

# Exit 0 when version $1 >= version $2 (major.minor.patch; suffixes ignored).
version_at_least() {
  awk -v have="$1" -v need="$2" 'BEGIN {
    split(have, h, "."); split(need, n, ".")
    for (i = 1; i <= 3; i++) {
      if (h[i] + 0 > n[i] + 0) exit 0
      if (h[i] + 0 < n[i] + 0) exit 1
    }
    exit 0
  }'
}

check_herdr_version() {
  herdr_version=$(herdr --version </dev/null 2>/dev/null | awk 'NR == 1 { print $2 }')
  [ -n "$herdr_version" ] || die "could not read the herdr version from 'herdr --version'."
  version_at_least "$herdr_version" "$MIN_HERDR_VERSION" && return 0
  die "herdr $herdr_version is too old; oh-my-herdr needs herdr $MIN_HERDR_VERSION or newer.
  Upgrade it, then run this again:
    herdr update          if you installed herdr with its install script
    brew upgrade herdr    if you installed herdr with Homebrew"
}

ensure_herdr() {
  HERDR_READY=0
  if command -v herdr >/dev/null 2>&1; then
    check_herdr_version
    HERDR_READY=1
    say "Using herdr $herdr_version"
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    say "herdr was not found; installing it with Homebrew"
    act brew install herdr </dev/null
  else
    say "herdr was not found; installing it with $HERDR_INSTALL_URL"
    if [ "$DRY_RUN" = 1 ]; then
      plan "curl -fsSL $HERDR_INSTALL_URL | sh"
    else
      curl -fsSL "$HERDR_INSTALL_URL" | sh
    fi
  fi
  [ "$DRY_RUN" = 0 ] || return 0
  if ! command -v herdr >/dev/null 2>&1 && [ -x "$HOME/.local/bin/herdr" ]; then
    warn "$HOME/.local/bin is not on your PATH. Add it in your shell profile to run herdr."
    PATH=$HOME/.local/bin:$PATH
    export PATH
  fi
  command -v herdr >/dev/null 2>&1 || die "herdr was installed but is not on PATH. Open a new shell and run this again."
  check_herdr_version
  HERDR_READY=1
}

# --- Source ---------------------------------------------------------------

# Sets SRC_DIR to the oh-my-herdr tree to install from, cloning or updating
# OMH_DIR unless OMH_SOURCE points at a local checkout.
prepare_source() {
  SRC_READY=1
  if [ -n "${OMH_SOURCE:-}" ]; then
    [ -f "$OMH_SOURCE/config/base.toml" ] ||
      die "OMH_SOURCE=$OMH_SOURCE is not an oh-my-herdr checkout (config/base.toml is missing)."
    SRC_DIR=$(cd "$OMH_SOURCE" && pwd)
    if [ -d "$OMH_DIR" ] && [ "$(cd "$OMH_DIR" && pwd -P)" = "$(cd "$SRC_DIR" && pwd -P)" ]; then
      die "OMH_SOURCE and OMH_DIR are the same directory ($SRC_DIR). Point OMH_DIR elsewhere: --uninstall deletes it."
    fi
    SOURCE_KIND=local:$SRC_DIR
    say "Installing from the local checkout $SRC_DIR"
    return 0
  fi

  SRC_DIR=$OMH_DIR
  SOURCE_KIND=git
  if [ -d "$OMH_DIR/.git" ]; then
    say "Updating $OMH_DIR"
    act git -C "$OMH_DIR" pull --ff-only </dev/null
  elif [ -d "$OMH_DIR" ] && [ -n "$(ls -A "$OMH_DIR")" ]; then
    die "$OMH_DIR exists but is not a git checkout. Run with --uninstall, or set OMH_DIR to another directory."
  else
    say "Downloading oh-my-herdr into $OMH_DIR"
    act mkdir -p "$(dirname "$OMH_DIR")"
    act git clone --depth 1 "$REPO_URL" "$OMH_DIR" </dev/null
    [ "$DRY_RUN" = 0 ] || SRC_READY=0
  fi
}

# --- Modules --------------------------------------------------------------

# Print every module name in the source, one per line, in file-name order.
available_modules() {
  for module_file in "$SRC_DIR"/config/modules/*.toml; do
    [ -f "$module_file" ] || continue
    module_name=${module_file##*/}
    module_name=${module_name%.toml}
    case "$module_name" in
      *[!A-Za-z0-9._-]*) continue ;;
    esac
    printf '%s\n' "$module_name"
  done
}

# Print the tool a module needs, from its "# Requires: <tool> on PATH" line.
module_requirement() {
  sed -n 's/^# Requires: *\([A-Za-z0-9._-][A-Za-z0-9._-]*\) on PATH.*/\1/p' \
    "$SRC_DIR/config/modules/$1.toml" | head -n 1
}

requirement_met() {
  needed=$(module_requirement "$1")
  [ -z "$needed" ] || command -v "$needed" >/dev/null 2>&1
}

add_module() {
  has_word "$1" "$SELECTED" || SELECTED=${SELECTED:+$SELECTED }$1
}

# Sets SELECTED to the space-separated module names to install, in order.
select_modules() {
  SELECTED=''
  if [ "$SRC_READY" = 0 ]; then
    plan "choose modules after the download (${MODULES_ARG:-default selection})"
    return 0
  fi
  available=$(available_modules | tr '\n' ' ')

  if [ "$MODULES_SET" = 1 ]; then
    case "$MODULES_ARG" in
      all) for name in $available; do add_module "$name"; done ;;
      none) ;;
      *)
        rest=$MODULES_ARG,
        while [ -n "$rest" ]; do
          name=${rest%%,*}
          rest=${rest#*,}
          [ -n "$name" ] || continue
          has_word "$name" "$available" || die "unknown module: $name (available: ${available% })"
          add_module "$name"
        done
        ;;
    esac
  elif [ -f "$STATE_FILE" ] && grep -q '^modules=' "$STATE_FILE"; then
    for name in $(state_get modules); do
      if has_word "$name" "$available"; then
        add_module "$name"
      else
        warn "module $name no longer exists; skipping it."
      fi
    done
  else
    for name in $available; do
      if has_word "$name" "$DEFAULT_MODULES" && requirement_met "$name"; then
        add_module "$name"
      fi
    done
  fi

  for name in $SELECTED; do
    requirement_met "$name" ||
      warn "module $name needs $(module_requirement "$name"), which is not on PATH; its keybinding will not work until you install it."
  done
  say "Modules: ${SELECTED:-none}"
}

# --- Config ---------------------------------------------------------------

# Write the managed config to $1: the marker header, base.toml, the selected
# modules, then local.toml, joined by newlines (as tests/helpers/config_lint.py
# compose joins files).
compose_config() {
  {
    printf '%s Generated by install.sh; changes here are overwritten.\n' "$MARKER"
    printf '# Put your own settings in %s instead.\n' "$LOCAL_FILE"
    printf '\n'
    cat "$SRC_DIR/config/base.toml"
    for name in $SELECTED; do
      printf '\n'
      cat "$SRC_DIR/config/modules/$name.toml"
    done
    if [ -f "$LOCAL_FILE" ]; then
      printf '\n'
      cat "$LOCAL_FILE"
    fi
  } >"$1"
}

install_config() {
  need_backup=0
  if exists "$CONFIG_FILE" && ! is_managed "$CONFIG_FILE"; then
    need_backup=1
  fi
  local_note=''
  [ ! -f "$LOCAL_FILE" ] || local_note=", then $LOCAL_FILE"

  if [ "$DRY_RUN" = 1 ]; then
    [ "$need_backup" = 0 ] || plan "back up $CONFIG_FILE to $BACKUP_FILE"
    plan "write $CONFIG_FILE: base.toml, modules (${SELECTED:-none})$local_note"
    plan "check it with 'herdr config check' before it replaces the current config"
    return 0
  fi

  config_dir=$(dirname "$CONFIG_FILE")
  mkdir -p "$config_dir"
  TMP_CONFIG=$config_dir/.config.toml.oh-my-herdr.$$
  compose_config "$TMP_CONFIG"

  # herdr reads the file named by HERDR_CONFIG_PATH; a path argument to
  # `config check` would only print usage.
  if ! check_output=$(HERDR_CONFIG_PATH=$TMP_CONFIG herdr config check </dev/null 2>&1); then
    printf '%s\n' "$check_output" >&2
    rm -f "$TMP_CONFIG"
    die "herdr rejected the generated config, so $CONFIG_FILE was not changed."
  fi

  if [ -f "$CONFIG_FILE" ] && cmp -s "$TMP_CONFIG" "$CONFIG_FILE"; then
    rm -f "$TMP_CONFIG"
    say "$CONFIG_FILE is already up to date"
    return 0
  fi
  if [ "$need_backup" = 1 ]; then
    mv "$CONFIG_FILE" "$BACKUP_FILE"
    say "Saved your previous config as $BACKUP_FILE"
  fi
  mv -f "$TMP_CONFIG" "$CONFIG_FILE"
  say "Wrote $CONFIG_FILE"
}

# --- Plugins --------------------------------------------------------------

link_plugins() {
  LINKED=''
  PLUGIN_FAILURES=0
  [ "$SRC_READY" = 1 ] || return 0
  for manifest in "$SRC_DIR"/plugins/*/herdr-plugin.toml; do
    [ -f "$manifest" ] || continue
    plugin_dir=$(dirname "$manifest")
    plugin_id=$(sed -n 's/^id *= *"\([^"]*\)".*/\1/p' "$manifest" | head -n 1)
    case "$plugin_id" in
      '' | *[!A-Za-z0-9._-]*)
        warn "skipping $plugin_dir: herdr-plugin.toml has no valid id."
        continue
        ;;
    esac
    if [ "$DRY_RUN" = 1 ]; then
      act herdr plugin link "$plugin_dir"
    elif link_output=$(herdr plugin link "$plugin_dir" </dev/null 2>&1); then
      LINKED=${LINKED:+$LINKED }$plugin_id
      say "Linked plugin $plugin_id"
    else
      printf '%s\n' "$link_output" >&2
      warn "could not link plugin $plugin_id"
      PLUGIN_FAILURES=1
    fi
  done
}

unlink_plugins() {
  for plugin_id in $1; do
    if [ "$DRY_RUN" = 1 ]; then
      act herdr plugin unlink "$plugin_id"
    elif [ "$HERDR_READY" = 1 ] && herdr plugin unlink "$plugin_id" </dev/null >/dev/null 2>&1; then
      say "Unlinked plugin $plugin_id"
    else
      warn "could not unlink plugin $plugin_id; herdr unlinks plugins only while it is running. Start herdr, then run: herdr plugin unlink $plugin_id"
    fi
  done
}

# --- State and reload -----------------------------------------------------

write_state() {
  if [ "$DRY_RUN" = 1 ]; then
    plan "record what was installed in $STATE_FILE"
    return 0
  fi
  state_backup=''
  ! exists "$BACKUP_FILE" || state_backup=$BACKUP_FILE
  mkdir -p "$OMH_DIR"
  {
    printf '%s\n' "# oh-my-herdr install state, read by install.sh --uninstall."
    printf 'version=1\n'
    printf 'config=%s\n' "$CONFIG_FILE"
    printf 'backup=%s\n' "$state_backup"
    printf 'modules=%s\n' "$SELECTED"
    printf 'plugins=%s\n' "$LINKED"
    printf 'source=%s\n' "$SOURCE_KIND"
  } >"$STATE_FILE"
}

# Apply the config to a running herdr server. Never fails the install: with
# no server, the new config is read the next time herdr starts.
reload_herdr() {
  if [ "$DRY_RUN" = 1 ]; then
    plan "reload the config in herdr if a herdr server is running"
    return 0
  fi
  if [ "$HERDR_READY" = 1 ] &&
    herdr status server </dev/null 2>/dev/null | grep -qx 'status: running'; then
    if reload_output=$(herdr server reload-config </dev/null 2>&1); then
      say "Reloaded the config in the running herdr server"
    else
      warn "could not reload herdr: $reload_output"
      warn "restart herdr, or run 'herdr server reload-config', to apply the new config."
    fi
  else
    say "No running herdr server found; changes apply the next time herdr starts."
  fi
}

# --- Commands -------------------------------------------------------------

run_install() {
  [ "$DRY_RUN" = 0 ] || say "dry run: printing what would happen; nothing will be changed."
  check_config_conflict
  ensure_herdr
  prepare_source
  select_modules
  install_config
  link_plugins
  write_state
  reload_herdr
  [ "$DRY_RUN" = 0 ] || return 0

  say "oh-my-herdr is installed."
  ! exists "$BACKUP_FILE" || say "Your previous config is saved as $BACKUP_FILE"
  say "Uninstall with: curl -fsSL $INSTALLER_URL | sh -s -- --uninstall --yes"
  [ "$PLUGIN_FAILURES" = 0 ] || die "some plugins could not be linked; see the warnings above."
}

confirm_uninstall() {
  [ "$ASSUME_YES" = 0 ] || return 0
  [ "$DRY_RUN" = 0 ] || return 0
  [ -t 0 ] || die "refusing to uninstall without confirmation: stdin is not a terminal. Re-run with --yes to confirm."
  printf 'Remove oh-my-herdr and restore your previous herdr config? [y/N] '
  read -r answer || answer=''
  case "$answer" in
    y | Y | yes | Yes | YES) ;;
    *) die "uninstall cancelled; nothing was changed." ;;
  esac
}

restore_config() {
  if exists "$BACKUP_FILE"; then
    if exists "$CONFIG_FILE" && ! is_managed "$CONFIG_FILE"; then
      warn "$CONFIG_FILE is not managed by oh-my-herdr, so it was left in place, and so was the backup $BACKUP_FILE."
    elif [ "$DRY_RUN" = 1 ]; then
      plan "restore $BACKUP_FILE to $CONFIG_FILE"
    else
      mv -f "$BACKUP_FILE" "$CONFIG_FILE"
      say "Restored your previous config from $BACKUP_FILE"
    fi
  elif is_managed "$CONFIG_FILE"; then
    act rm -f "$CONFIG_FILE"
    [ "$DRY_RUN" = 1 ] || say "Removed $CONFIG_FILE"
  elif exists "$CONFIG_FILE"; then
    say "$CONFIG_FILE is not managed by oh-my-herdr; left in place."
  fi
}

remove_omh_dir() {
  exists "$OMH_DIR" || return 0
  if [ ! -f "$STATE_FILE" ]; then
    warn "$OMH_DIR has no oh-my-herdr install state, so it was not removed."
    return 0
  fi
  case "$(cd "$OMH_DIR" && pwd -P)" in
    / | "$(cd "$HOME" && pwd -P)") die "refusing to remove $OMH_DIR." ;;
  esac
  act rm -rf "$OMH_DIR"
  [ "$DRY_RUN" = 1 ] || say "Removed $OMH_DIR"
}

run_uninstall() {
  [ "$DRY_RUN" = 0 ] || say "dry run: printing what would happen; nothing will be changed."
  confirm_uninstall
  recorded_config=$(state_get config)
  if [ -n "$recorded_config" ]; then
    CONFIG_FILE=$recorded_config
    BACKUP_FILE=$CONFIG_FILE$BACKUP_SUFFIX
  fi
  HERDR_READY=0
  ! command -v herdr >/dev/null 2>&1 || HERDR_READY=1

  unlink_plugins "$(state_get plugins)"
  restore_config
  remove_omh_dir
  reload_herdr
  [ "$DRY_RUN" = 0 ] || return 0

  say "oh-my-herdr was removed."
  [ ! -f "$LOCAL_FILE" ] || say "Your own settings in $LOCAL_FILE were kept."
  say "herdr itself was not removed. To remove it: 'brew uninstall herdr' (Homebrew) or 'rm ~/.local/bin/herdr' (install script)."
}

# --- Main -----------------------------------------------------------------

cleanup() {
  if [ -n "$TMP_CONFIG" ]; then
    rm -f "$TMP_CONFIG"
  fi
}

main() {
  DRY_RUN=0
  ASSUME_YES=0
  MODE=install
  MODULES_SET=0
  MODULES_ARG=''
  TMP_CONFIG=''
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  setup_colors
  parse_args "$@"
  preflight
  resolve_paths
  if [ "$MODE" = uninstall ]; then
    run_uninstall
  else
    run_install
  fi
}

main "$@"
