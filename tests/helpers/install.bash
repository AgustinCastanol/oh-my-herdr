# shellcheck shell=bash
# Helpers for tests/install.bats. Load after helpers/common.
#
# Every test gets a throwaway HOME, a source tree (OMH_SOURCE) copied from
# config/, and a PATH made of exactly two directories: stub commands, and
# symlinks to the system utilities install.sh needs. Nothing else on the host
# (a real herdr, brew, lazygit, git, or curl) is visible to install.sh, which
# runs under `env -i`, so no HERDR_* or OMH_* variable leaks in either.

STUBS_DIR="$BATS_TEST_DIRNAME/stubs"
INSTALL_SH="$REPO_ROOT/install.sh"
# Shell that runs install.sh. Override to check POSIX compliance, for example
# INSTALL_SHELL=/bin/dash bats tests/install.bats.
INSTALL_SHELL="${INSTALL_SHELL:-sh}"
export STUBS_DIR INSTALL_SH INSTALL_SHELL

# System utilities install.sh and the stubs call. Everything else (shell
# builtins aside) is unavailable to them.
SYSTEM_UTILS="awk cat cmp cp dirname grep head ln ls mkdir mktemp mv rm rmdir sed sh tr uname"

setup_install_env() {
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  TEST_BIN="$BATS_TEST_TMPDIR/bin"
  TEST_SYSBIN="$BATS_TEST_TMPDIR/sysbin"
  TEST_TMP="$BATS_TEST_TMPDIR/tmp"
  TEST_SOURCE="$BATS_TEST_TMPDIR/source"
  STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  CONFIG_FILE="$TEST_HOME/.config/herdr/config.toml"
  BACKUP_FILE="$CONFIG_FILE.pre-oh-my-herdr"
  OMH_DATA_DIR="$TEST_HOME/.local/share/oh-my-herdr"
  STATE_FILE="$OMH_DATA_DIR/.install-state"
  OWNER_FILE="$OMH_DATA_DIR/.oh-my-herdr"
  TEST_USER_DIR="$TEST_HOME/.config/oh-my-herdr"
  LOCAL_TOML="$TEST_USER_DIR/local.toml"
  export TEST_HOME TEST_BIN TEST_SYSBIN TEST_TMP TEST_SOURCE STUB_LOG CONFIG_FILE \
    BACKUP_FILE OMH_DATA_DIR STATE_FILE OWNER_FILE TEST_USER_DIR LOCAL_TOML

  mkdir -p "$TEST_HOME" "$TEST_BIN" "$TEST_SYSBIN" "$TEST_TMP" "$TEST_SOURCE"
  : >"$STUB_LOG"
  cp -R "$CONFIG_DIR" "$TEST_SOURCE/config"

  local util path
  for util in $SYSTEM_UTILS; do
    path="$(command -v "$util")" || {
      echo "missing system utility: $util" >&2
      return 1
    }
    ln -s "$path" "$TEST_SYSBIN/$util"
  done
  INSTALL_SHELL_PATH="$(command -v "$INSTALL_SHELL")"

  # Extra VAR=value pairs for install.sh; tests append to it.
  INSTALL_ENV=("OMH_SOURCE=$TEST_SOURCE")
  use_stub git
  use_stub curl
  use_stub herdr
}

# Put a stub command on PATH, or take it off.
use_stub() { ln -sf "$STUBS_DIR/$1" "$TEST_BIN/$1"; }
remove_stub() { rm -f "$TEST_BIN/$1"; }

# Run a command with the environment install.sh gets: env -i, the test HOME
# and TMPDIR, the stub settings, INSTALL_ENV, and the two-directory PATH.
run_in_install_env() {
  run env -i \
    PATH="$TEST_BIN:$TEST_SYSBIN" \
    HOME="$TEST_HOME" \
    TMPDIR="$TEST_TMP" \
    TERM=dumb \
    STUB_LOG="$STUB_LOG" \
    STUBS_DIR="$STUBS_DIR" \
    TEST_BIN="$TEST_BIN" \
    ${INSTALL_ENV[@]+"${INSTALL_ENV[@]}"} \
    "$@"
}

run_installer() {
  run_in_install_env "$INSTALL_SHELL_PATH" "$INSTALL_SH" "$@"
}

# Print a listing of every path under the test HOME with a checksum of each
# file, to compare before and after a command that must change nothing.
snapshot_home() {
  (
    cd "$TEST_HOME" || exit 1
    find . -print | LC_ALL=C sort
    find . -type f -exec cksum {} \; | LC_ALL=C sort
  )
}

# Print the config body (everything after the marker header block) of a
# config written by install.sh.
config_body() {
  sed '1,/^$/d' "$1"
}

# Print the file install.sh should use for a layer path such as keys.toml or
# themes/gentle.toml: the copy in the user dir if there is one, else the
# shipped file.
layer_path() {
  if [ -f "$TEST_USER_DIR/$1" ]; then
    printf '%s\n' "$TEST_USER_DIR/$1"
  else
    printf '%s\n' "$TEST_SOURCE/config/$1"
  fi
}

# Print what the config body should be, in install.sh's order: base.toml,
# the theme named first, keys.toml, then the named modules, each resolved
# with layer_path and joined the way config_lint.py compose joins files.
# Extra file paths given after `--` are appended last (for local.toml).
# Usage: expected_body THEME [MODULE...] [-- FILE...]
expected_body() {
  local parts=("$(layer_path base.toml)" "$(layer_path "themes/$1.toml")" "$(layer_path keys.toml)")
  shift
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    parts+=("$(layer_path "modules/$1.toml")")
    shift
  done
  [ "${1:-}" = -- ] && shift
  config_lint compose "${parts[@]}" "$@"
}

# Copy the fixture plugin into the test source as plugins/<dir>, with the
# given plugin id.
add_plugin() {
  local dir="$TEST_SOURCE/plugins/$1"
  mkdir -p "$dir"
  sed "s/^id = .*/id = \"$2\"/" "$BATS_TEST_DIRNAME/fixtures/plugins/demo/herdr-plugin.toml" \
    >"$dir/herdr-plugin.toml"
}

# Like add_plugin, but the manifest also declares "# Requires: <tool> on PATH".
add_plugin_requiring() {
  add_plugin "$1" "$2"
  printf '# Requires: %s on PATH\n' "$3" | cat - "$TEST_SOURCE/plugins/$1/herdr-plugin.toml" \
    >"$TEST_SOURCE/plugins/$1/manifest.tmp"
  mv "$TEST_SOURCE/plugins/$1/manifest.tmp" "$TEST_SOURCE/plugins/$1/herdr-plugin.toml"
}

# Print the value of KEY from the install state file.
state_value() {
  sed -n "s/^$1=//p" "$STATE_FILE"
}
