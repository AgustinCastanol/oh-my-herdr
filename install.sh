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
DEFAULT_MODULES="engram git scratch sidebar"
# Theme from config/themes/ used when --theme is not given and no earlier
# choice is recorded.
DEFAULT_THEME=gentle
# First line of every config this script writes. It is how a config is
# recognised as managed (regenerate it) rather than the user's (back it up).
MARKER="# Managed by oh-my-herdr."
BACKUP_SUFFIX=.pre-oh-my-herdr
STATE_NAME=.install-state
# Written into OMH_DIR when this script creates it. --uninstall deletes
# OMH_DIR recursively only while this file says the directory is a clone this
# script made; otherwise it removes only the files it wrote.
OWNER_NAME=.oh-my-herdr

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
  --theme NAME     Theme to use, from config/themes/ or your themes/.
                   Default: the theme chosen last time, or "$DEFAULT_THEME".
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

Your files (in \${XDG_CONFIG_HOME:-~/.config}/oh-my-herdr):
  base.toml, keys.toml, themes/NAME.toml, modules/NAME.toml
                     replace the shipped file of the same name; new theme
                     and module names can be selected like shipped ones
  local.toml         appended last, for settings that add to the config
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
      --theme)
        [ "$#" -ge 2 ] || die "--theme needs a theme name."
        THEME_ARG=$2
        THEME_SET=1
        shift 2
        ;;
      --theme=*)
        THEME_ARG=${1#--theme=}
        THEME_SET=1
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
  if [ "$THEME_SET" = 1 ] && [ -z "$THEME_ARG" ]; then
    die "--theme needs a theme name."
  fi
  if [ "$MODE" = uninstall ] && [ "$MODULES_SET" = 1 ]; then
    die "--modules cannot be combined with --uninstall."
  fi
  if [ "$MODE" = uninstall ] && [ "$THEME_SET" = 1 ]; then
    die "--theme cannot be combined with --uninstall."
  fi
}

resolve_paths() {
  : "${HOME:?HOME is not set}"
  CONFIG_FILE=${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}
  BACKUP_FILE=$CONFIG_FILE$BACKUP_SUFFIX
  OMH_DIR=${OMH_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/oh-my-herdr}
  while :; do
    case "$OMH_DIR" in
      ?*/) OMH_DIR=${OMH_DIR%/} ;;
      *) break ;;
    esac
  done
  STATE_FILE=$OMH_DIR/$STATE_NAME
  OWNER_FILE=$OMH_DIR/$OWNER_NAME
  # Your files: local.toml, plus copies of shipped layers that replace them.
  USER_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-herdr
  LOCAL_FILE=$USER_DIR/local.toml
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

# Print an absolute path with symlinks resolved, for a path that may not
# exist yet: the deepest existing ancestor is resolved, the rest is appended.
physical_path() {
  pp_dir=$1
  pp_rest=''
  while [ ! -d "$pp_dir" ]; do
    pp_rest=/${pp_dir##*/}$pp_rest
    pp_parent=$(dirname "$pp_dir")
    [ "$pp_parent" != "$pp_dir" ] || break
    pp_dir=$pp_parent
  done
  pp_dir=$(cd "$pp_dir" && pwd -P)
  printf '%s%s\n' "${pp_dir%/}" "$pp_rest"
}

# True when path $1 equals path $2 or is inside it (both physical).
path_within() {
  case "$1" in
    "$2" | "$2"/*) return 0 ;;
  esac
  return 1
}

# Print how this script created OMH_DIR ("git" for a clone, "local" for a
# directory that only holds install state), or nothing when it did not.
owner_kind() {
  if [ ! -f "$OWNER_FILE" ]; then
    printf '%s' "$ADOPTED_KIND"
    return 0
  fi
  sed -n 's/^kind=//p' "$OWNER_FILE" | head -n 1
}

# Adopt an OMH_DIR from an installer that predates the ownership marker: a
# valid state file with source=git in a clone, or with a local source as the
# only file in the directory. Anything else is not adopted.
adopt_legacy_omh_dir() {
  for state_key in version=1 config= modules= plugins= source=; do
    grep -q "^$state_key" "$STATE_FILE" 2>/dev/null || return 1
  done
  case "$(state_get source)" in
    git) [ -d "$OMH_DIR/.git" ] || return 1 && ADOPTED_KIND=git ;;
    local:?*) [ "$(ls -A "$OMH_DIR")" = "$STATE_NAME" ] || return 1 && ADOPTED_KIND=local ;;
    *) return 1 ;;
  esac
  if [ "$DRY_RUN" = 1 ]; then
    plan "mark $OMH_DIR, installed before the ownership marker existed, as created by oh-my-herdr"
  else
    write_owner_marker "$ADOPTED_KIND"
  fi
}

write_owner_marker() {
  {
    printf '%s\n' "# Created by the oh-my-herdr installer."
    if [ "$1" = git ]; then
      printf '%s\n' "# install.sh --uninstall deletes this directory while this file is here."
    else
      printf '%s\n' "# install.sh --uninstall removes only the files it wrote here."
    fi
    printf 'kind=%s\n' "$1"
  } >"$OWNER_FILE"
}

# True when a herdr server answers on its socket.
server_running() {
  [ "$HERDR_READY" = 1 ] &&
    herdr status server </dev/null 2>/dev/null | grep -qx 'status: running'
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

# Download herdr's install script to a file, check it, then run it. A failed
# or empty download stops here, before anything is changed.
run_herdr_install_script() {
  if [ "$DRY_RUN" = 1 ]; then
    plan "download $HERDR_INSTALL_URL to a temporary file and run it with sh"
    return 0
  fi
  HERDR_SCRIPT=$(mktemp "${TMPDIR:-/tmp}/herdr-install.XXXXXX") ||
    die "could not create a temporary file for the herdr installer."
  if ! curl -fsSL "$HERDR_INSTALL_URL" -o "$HERDR_SCRIPT" </dev/null; then
    die "could not download $HERDR_INSTALL_URL; nothing was changed.
  Install herdr yourself (https://herdr.dev), then run this again."
  fi
  [ -s "$HERDR_SCRIPT" ] ||
    die "the herdr installer downloaded from $HERDR_INSTALL_URL is empty; nothing was changed."
  sh "$HERDR_SCRIPT" </dev/null || die "the herdr installer failed; see its output above."
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
    run_herdr_install_script
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

# Refuse an OMH_DIR that holds files this script did not put there: it would
# later write into it, and --uninstall would remove things from it.
check_omh_dir_owner() {
  if [ -e "$OMH_DIR" ] && [ ! -d "$OMH_DIR" ]; then
    die "OMH_DIR=$OMH_DIR exists and is not a directory."
  fi
  [ -d "$OMH_DIR" ] || return 0
  [ -z "$(owner_kind)" ] || return 0
  [ -n "$(ls -A "$OMH_DIR")" ] || return 0
  ! adopt_legacy_omh_dir || return 0
  die "$OMH_DIR already exists, is not empty, and was not created by oh-my-herdr.
  Nothing was changed. Set OMH_DIR to a new directory, or move this one away."
}

# Sets SRC_DIR to the oh-my-herdr tree to install from. With OMH_SOURCE that
# is the local checkout. Otherwise an existing clone in OMH_DIR is updated,
# or the repository is cloned into a temporary directory that place_source
# later moves to OMH_DIR, so checks and --dry-run can read it first.
prepare_source() {
  STAGE_DIR=''
  if [ -n "${OMH_SOURCE:-}" ]; then
    [ -f "$OMH_SOURCE/config/base.toml" ] ||
      die "OMH_SOURCE=$OMH_SOURCE is not an oh-my-herdr checkout (config/base.toml is missing)."
    SRC_DIR=$(cd "$OMH_SOURCE" && pwd)
    source_physical=$(physical_path "$SRC_DIR")
    omh_physical=$(physical_path "$OMH_DIR")
    if path_within "$omh_physical" "$source_physical" || path_within "$source_physical" "$omh_physical"; then
      die "OMH_DIR=$OMH_DIR overlaps the source checkout $SRC_DIR. Point OMH_DIR at a directory outside it."
    fi
    check_omh_dir_owner
    SOURCE_KIND=local:$SRC_DIR
    say "Installing from the local checkout $SRC_DIR"
    return 0
  fi

  SOURCE_KIND=git
  check_omh_dir_owner
  case "$(owner_kind)" in
    git)
      SRC_DIR=$OMH_DIR
      say "Updating $OMH_DIR"
      act git -C "$OMH_DIR" pull --ff-only </dev/null
      return 0
      ;;
    local)
      die "$OMH_DIR holds an install made from a local checkout (OMH_SOURCE).
  Run this with OMH_SOURCE again, or run --uninstall first."
      ;;
  esac

  STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/oh-my-herdr.XXXXXX") ||
    die "could not create a temporary directory."
  SRC_DIR=$STAGE_DIR/oh-my-herdr
  say "Downloading oh-my-herdr from $REPO_URL"
  git clone --depth 1 "$REPO_URL" "$SRC_DIR" </dev/null ||
    die "could not clone $REPO_URL; nothing was changed."
}

# Move a fresh clone from its temporary directory to OMH_DIR.
place_source() {
  [ -n "$STAGE_DIR" ] || return 0
  if [ "$DRY_RUN" = 1 ]; then
    plan "move the downloaded copy to $OMH_DIR"
    return 0
  fi
  mkdir -p "$(dirname "$OMH_DIR")"
  # check_omh_dir_owner allowed an existing OMH_DIR only if it is empty.
  [ ! -d "$OMH_DIR" ] || rmdir "$OMH_DIR"
  mv "$SRC_DIR" "$OMH_DIR"
  SRC_DIR=$OMH_DIR
  write_owner_marker git
  say "Downloaded oh-my-herdr into $OMH_DIR"
}

# --- Modules --------------------------------------------------------------

# Print the file to use for a layer path under config/, such as keys.toml or
# themes/gentle.toml: your copy in USER_DIR when it exists, else the shipped
# file. Your copy replaces the shipped file as a whole.
layer_file() {
  if [ -f "$USER_DIR/$1" ]; then
    printf '%s\n' "$USER_DIR/$1"
  else
    printf '%s\n' "$SRC_DIR/config/$1"
  fi
}

# Print the names of the layers in a directory (modules or themes), shipped
# ones in file-name order, then ones that only USER_DIR has, space-separated.
layer_names() {
  layer_list=''
  for layer_path in "$SRC_DIR/config/$1"/*.toml "$USER_DIR/$1"/*.toml; do
    [ -f "$layer_path" ] || continue
    layer_name=${layer_path##*/}
    layer_name=${layer_name%.toml}
    case "$layer_name" in
      *[!A-Za-z0-9._-]*) continue ;;
    esac
    has_word "$layer_name" "$layer_list" || layer_list=${layer_list:+$layer_list }$layer_name
  done
  printf '%s' "$layer_list"
}

# Print the tools a module or plugin file declares in its first "# Requires:"
# line, one per line: each comma-separated "<tool> on PATH" entry.
required_tools() {
  sed -n 's/^# Requires: *//p' "$1" | head -n 1 | tr ',' '\n' |
    sed -n 's/^ *\([A-Za-z0-9._-][A-Za-z0-9._-]*\) on PATH.*/\1/p'
}

# Print the required tools of a file that are not on PATH, space-separated.
missing_tools() {
  missing=''
  for tool in $(required_tools "$1"); do
    command -v "$tool" >/dev/null 2>&1 || missing=${missing:+$missing }$tool
  done
  printf '%s' "$missing"
}

requirement_met() {
  [ -z "$(missing_tools "$(layer_file "modules/$1.toml")")" ]
}

add_module() {
  has_word "$1" "$SELECTED" || SELECTED=${SELECTED:+$SELECTED }$1
}

# Sets SELECTED to the space-separated module names to install, in order.
select_modules() {
  SELECTED=''
  available=$(layer_names modules)

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
      warn "module $name needs $(missing_tools "$(layer_file "modules/$name.toml")"), which is not on PATH; its keybinding will not work until you install it."
  done
  say "Modules: ${SELECTED:-none}"
}

# --- Theme ----------------------------------------------------------------

# Sets THEME to the theme to install: --theme, else the one recorded at the
# last install, else DEFAULT_THEME.
select_theme() {
  themes=$(layer_names themes)
  if [ "$THEME_SET" = 1 ]; then
    THEME=$THEME_ARG
    has_word "$THEME" "$themes" || die "unknown theme: $THEME (available: ${themes% })"
  else
    THEME=$(state_get theme)
    if [ -n "$THEME" ] && ! has_word "$THEME" "$themes"; then
      warn "theme $THEME no longer exists; using $DEFAULT_THEME."
      THEME=''
    fi
    THEME=${THEME:-$DEFAULT_THEME}
    has_word "$THEME" "$themes" || die "the default theme $THEME is missing from $SRC_DIR/config/themes."
  fi
  say "Theme: $THEME"
}

# --- Config ---------------------------------------------------------------

# Print, in compose order, the layer paths under config/ for this install.
layer_paths() {
  printf '%s\n' base.toml "themes/$THEME.toml" keys.toml
  for name in $SELECTED; do
    printf '%s\n' "modules/$name.toml"
  done
}

# Say which layers come from USER_DIR instead of the shipped files.
report_overrides() {
  for layer_path in $(layer_paths); do
    [ -f "$USER_DIR/$layer_path" ] || continue
    if [ -f "$SRC_DIR/config/$layer_path" ]; then
      say "Using your $USER_DIR/$layer_path instead of the shipped $layer_path"
    else
      say "Using your $USER_DIR/$layer_path"
    fi
  done
}

# Write the managed config to $1: the marker header, then base.toml, the
# theme, keys.toml, and the selected modules (each from USER_DIR when you
# have a copy there), then local.toml, joined by newlines (as
# tests/helpers/config_lint.py compose joins files).
compose_config() {
  {
    printf '%s Generated by install.sh; changes here are overwritten.\n' "$MARKER"
    printf '# Customize in %s instead: local.toml, or copies of shipped layers.\n' "$USER_DIR"
    for layer_path in $(layer_paths); do
      printf '\n'
      cat "$(layer_file "$layer_path")"
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
    plan "write $CONFIG_FILE: base.toml, theme ($THEME), modules (${SELECTED:-none})$local_note"
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

# Link every plugin in the source, and set PLUGINS_STATE to the plugins to
# record: the ones recorded earlier plus the ones linked now. A recorded
# plugin that is gone from the source is unlinked when herdr is running;
# otherwise it stays recorded, so a later install or --uninstall unlinks it.
link_plugins() {
  recorded_plugins=$(state_get plugins)
  present_plugins=''
  linked_plugins=''
  PLUGIN_FAILURES=0
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
    present_plugins="$present_plugins $plugin_id"
    plugin_missing=$(missing_tools "$manifest")
    if [ -n "$plugin_missing" ]; then
      if [ "$DRY_RUN" = 1 ]; then
        plan "skip plugin $plugin_id: it needs $plugin_missing, which is not on PATH"
      else
        warn "skipping plugin $plugin_id: it needs $plugin_missing, which is not on PATH. Install it and run this again."
      fi
      continue
    fi
    if [ "$DRY_RUN" = 1 ]; then
      act herdr plugin link "$plugin_dir"
    elif link_output=$(herdr plugin link "$plugin_dir" </dev/null 2>&1); then
      linked_plugins="$linked_plugins $plugin_id"
      say "Linked plugin $plugin_id"
    else
      printf '%s\n' "$link_output" >&2
      warn "could not link plugin $plugin_id"
      PLUGIN_FAILURES=1
    fi
  done

  PLUGINS_STATE=''
  for plugin_id in $recorded_plugins $linked_plugins; do
    ! has_word "$plugin_id" "$PLUGINS_STATE" || continue
    if has_word "$plugin_id" "$present_plugins"; then
      PLUGINS_STATE=${PLUGINS_STATE:+$PLUGINS_STATE }$plugin_id
    elif [ "$DRY_RUN" = 1 ]; then
      plan "unlink plugin $plugin_id, which oh-my-herdr no longer ships, if herdr is running"
    elif server_running && herdr plugin unlink "$plugin_id" </dev/null >/dev/null 2>&1; then
      say "Unlinked plugin $plugin_id, which oh-my-herdr no longer ships"
    else
      PLUGINS_STATE=${PLUGINS_STATE:+$PLUGINS_STATE }$plugin_id
      warn "plugin $plugin_id is no longer part of oh-my-herdr but is still linked. herdr unlinks plugins only while it is running: run this installer again then, or run: herdr plugin unlink $plugin_id"
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
  if [ ! -d "$OMH_DIR" ]; then
    mkdir -p "$OMH_DIR"
    write_owner_marker local
  elif [ -z "$(owner_kind)" ]; then
    # check_omh_dir_owner allowed this directory only because it was empty.
    write_owner_marker local
  fi
  {
    printf '%s\n' "# oh-my-herdr install state, read by install.sh --uninstall."
    printf 'version=1\n'
    printf 'config=%s\n' "$CONFIG_FILE"
    printf 'backup=%s\n' "$state_backup"
    printf 'theme=%s\n' "$THEME"
    printf 'modules=%s\n' "$SELECTED"
    printf 'plugins=%s\n' "$PLUGINS_STATE"
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
  if server_running; then
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
  # Checks and choices first; nothing outside a temporary directory changes
  # until herdr is known to be usable and every option is valid.
  check_config_conflict
  prepare_source
  select_theme
  select_modules
  report_overrides
  ensure_herdr
  place_source
  install_config
  link_plugins
  write_state
  reload_herdr
  [ "$DRY_RUN" = 0 ] || return 0

  say "oh-my-herdr is installed."
  ! exists "$BACKUP_FILE" || say "Your previous config is saved as $BACKUP_FILE"
  say "Uninstall with: curl -fsSL $INSTALLER_URL | sh -s -- --uninstall --yes"
  suggest_integrations
  [ "$PLUGIN_FAILURES" = 0 ] || die "some plugins could not be linked; see the warnings above."
}

# Print the commands that start the agent an integration is for, as herdr
# itself looks them up (herdr v0.9.5 src/integration/registry.rs).
integration_commands() {
  case "$1" in
    cursor) printf '%s\n' cursor-agent ;;
    antigravity-cli) printf '%s\n' agy ;;
    kilo) printf '%s\n' kilo kilo-code ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Suggest herdr integrations worth installing: outdated ones, and missing
# ones whose agent is on PATH. `herdr integration status` reads files only
# and needs no server. This never installs anything itself.
suggest_integrations() {
  [ "$HERDR_READY" = 1 ] || return 0
  parsed=0
  suggested=''
  if integration_status=$(herdr integration status </dev/null 2>/dev/null); then
    # Lines look like "claude: not installed (<path>)" or "codex: outdated
    # (v1 < v2) (<path>)"; experimental ones are "<name> (experimental): ...".
    while IFS= read -r line; do
      name=${line%%: *}
      state=${line#*: }
      case "$name" in
        '' | *[!a-z0-9-]*) continue ;;
      esac
      parsed=1
      case "$state" in
        outdated* | 'needs repair'*) ;;
        'not installed'*)
          agent_on_path=0
          for agent_command in $(integration_commands "$name"); do
            if command -v "$agent_command" >/dev/null 2>&1; then
              agent_on_path=1
            fi
          done
          [ "$agent_on_path" = 1 ] || continue
          ;;
        *) continue ;;
      esac
      suggested="$suggested $name"
    done <<EOF
$integration_status
EOF
  fi
  if [ "$parsed" = 0 ]; then
    say "Tip: run 'herdr integration status' to see which agent integrations you can install."
  elif [ -n "$suggested" ]; then
    say "Suggested herdr integrations (they let herdr resume agent sessions after a restart):"
    for name in $suggested; do
      printf '      herdr integration install %s\n' "$name"
    done
  fi
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

# Delete OMH_DIR recursively only when the ownership marker says this script
# cloned it. Otherwise remove only the files this script wrote there, and
# the directory only if nothing else is left in it.
remove_omh_dir() {
  [ -d "$OMH_DIR" ] || return 0
  if [ "$(owner_kind)" = git ]; then
    case "$(cd "$OMH_DIR" && pwd -P)" in
      / | "$(cd "$HOME" && pwd -P)") die "refusing to remove $OMH_DIR." ;;
    esac
    act rm -rf "$OMH_DIR"
    [ "$DRY_RUN" = 1 ] || say "Removed $OMH_DIR"
    return 0
  fi
  act rm -f "$STATE_FILE" "$OWNER_FILE"
  if [ "$DRY_RUN" = 1 ]; then
    plan "remove $OMH_DIR if nothing else is left in it"
  elif [ -z "$(ls -A "$OMH_DIR")" ]; then
    rmdir "$OMH_DIR"
    say "Removed $OMH_DIR"
  else
    say "Kept $OMH_DIR: it contains files oh-my-herdr did not create."
  fi
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
  [ ! -d "$USER_DIR" ] || say "Your own files in $USER_DIR were kept."
  say "herdr itself was not removed. To remove it: 'brew uninstall herdr' (Homebrew) or 'rm ~/.local/bin/herdr' (install script)."
}

# --- Main -----------------------------------------------------------------

cleanup() {
  if [ -n "$TMP_CONFIG" ]; then
    rm -f "$TMP_CONFIG"
  fi
  if [ -n "$HERDR_SCRIPT" ]; then
    rm -f "$HERDR_SCRIPT"
  fi
  # A directory made by mktemp -d in prepare_source; empty once place_source
  # has moved the clone out of it.
  if [ -n "$STAGE_DIR" ]; then
    rm -rf "$STAGE_DIR"
  fi
}

main() {
  DRY_RUN=0
  ASSUME_YES=0
  MODE=install
  MODULES_SET=0
  MODULES_ARG=''
  THEME_SET=0
  THEME_ARG=''
  TMP_CONFIG=''
  HERDR_SCRIPT=''
  STAGE_DIR=''
  ADOPTED_KIND=''
  HERDR_READY=0
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
