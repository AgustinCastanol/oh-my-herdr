# shellcheck shell=bash
# Helpers for tests/install.bats. Load after helpers/common.
#
# Every test gets a throwaway HOME, a bin directory of stub commands that is
# first on PATH, and a source tree (OMH_SOURCE) copied from config/. install.sh
# runs under `env -i`, so no HERDR_* or OMH_* variable from the caller leaks in.

STUBS_DIR="$BATS_TEST_DIRNAME/stubs"
INSTALL_SH="$REPO_ROOT/install.sh"
# Shell that runs install.sh. Override to check POSIX compliance, for example
# INSTALL_SHELL=/bin/dash bats tests/install.bats.
INSTALL_SHELL="${INSTALL_SHELL:-sh}"
export STUBS_DIR INSTALL_SH INSTALL_SHELL

setup_install_env() {
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  TEST_BIN="$BATS_TEST_TMPDIR/bin"
  TEST_SOURCE="$BATS_TEST_TMPDIR/source"
  STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  CONFIG_FILE="$TEST_HOME/.config/herdr/config.toml"
  BACKUP_FILE="$CONFIG_FILE.pre-oh-my-herdr"
  OMH_DATA_DIR="$TEST_HOME/.local/share/oh-my-herdr"
  STATE_FILE="$OMH_DATA_DIR/.install-state"
  LOCAL_TOML="$TEST_HOME/.config/oh-my-herdr/local.toml"
  export TEST_HOME TEST_BIN TEST_SOURCE STUB_LOG CONFIG_FILE BACKUP_FILE \
    OMH_DATA_DIR STATE_FILE LOCAL_TOML

  mkdir -p "$TEST_HOME" "$TEST_BIN" "$TEST_SOURCE"
  : >"$STUB_LOG"
  cp -R "$CONFIG_DIR" "$TEST_SOURCE/config"

  # Extra VAR=value pairs for install.sh; tests append to it.
  INSTALL_ENV=("OMH_SOURCE=$TEST_SOURCE")
  use_stub git
  use_stub curl
  use_stub herdr
}

# Put a stub command on PATH, or take it off.
use_stub() { ln -sf "$STUBS_DIR/$1" "$TEST_BIN/$1"; }
remove_stub() { rm -f "$TEST_BIN/$1"; }

# Run install.sh with a clean environment. PATH holds the stubs and the
# system directories only, so no real herdr, brew, or lazygit is found.
run_installer() {
  run env -i \
    PATH="$TEST_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$TEST_HOME" \
    TERM=dumb \
    STUB_LOG="$STUB_LOG" \
    STUBS_DIR="$STUBS_DIR" \
    TEST_BIN="$TEST_BIN" \
    ${INSTALL_ENV[@]+"${INSTALL_ENV[@]}"} \
    "$INSTALL_SHELL" "$INSTALL_SH" "$@"
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

# Print what the config body should be: base.toml, then the named modules,
# joined the way config_lint.py compose joins files. Extra file paths given
# after `--` are appended last (for local.toml).
expected_body() {
  local parts=("$TEST_SOURCE/config/base.toml")
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    parts+=("$TEST_SOURCE/config/modules/$1.toml")
    shift
  done
  [ "${1:-}" = -- ] && shift
  config_lint compose "${parts[@]}" "$@"
}

# Fail unless the stub log has a line equal to the given text.
assert_logged() {
  if ! grep -qxF -- "$1" "$STUB_LOG"; then
    printf 'expected stub log line: %s\nstub log:\n' "$1" >&2
    cat "$STUB_LOG" >&2
    return 1
  fi
}

# Fail if any stub log line starts with the given text.
refute_logged() {
  if grep -q -- "^$1" "$STUB_LOG"; then
    printf 'unexpected stub log line starting with: %s\n' "$1" >&2
    cat "$STUB_LOG" >&2
    return 1
  fi
}

# Print the value of KEY from the install state file.
state_value() {
  sed -n "s/^$1=//p" "$STATE_FILE"
}
