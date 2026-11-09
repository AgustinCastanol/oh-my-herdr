# shellcheck shell=bash
# Shared helpers for oh-my-herdr bats tests. Load with: load helpers/common

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
MODULES_DIR="$CONFIG_DIR/modules"
export REPO_ROOT CONFIG_DIR MODULES_DIR

# The vendored herdr config reference. Its file name is the single source of
# the pinned herdr version: tests/fixtures/herdr-<version>-config-reference.json.
# Exactly one such file must exist; see tests/fixtures/README.md.
find_herdr_reference() {
  local candidate found=""
  for candidate in "$BATS_TEST_DIRNAME"/fixtures/herdr-*-config-reference.json; do
    [ -e "$candidate" ] || continue
    if [ -n "$found" ]; then
      echo "more than one herdr config reference in tests/fixtures" >&2
      return 1
    fi
    found="$candidate"
  done
  if [ -z "$found" ]; then
    echo "no herdr config reference in tests/fixtures" >&2
    return 1
  fi
  HERDR_REFERENCE="$found"
  HERDR_REFERENCE_VERSION="${found##*/herdr-}"
  HERDR_REFERENCE_VERSION="${HERDR_REFERENCE_VERSION%-config-reference.json}"
  export HERDR_REFERENCE HERDR_REFERENCE_VERSION
}

# Run the offline config checker. See tests/helpers/config_lint.py for subcommands.
config_lint() {
  python3 -I "$BATS_TEST_DIRNAME/helpers/config_lint.py" "$@"
}

# Fill the MODULES array with every module file, in a stable order. Fails when
# there are none, so a loop over modules can never pass without checking
# anything. An array keeps paths that contain spaces intact.
load_modules() {
  local module
  MODULES=()
  for module in "$MODULES_DIR"/*.toml; do
    [ -e "$module" ] || continue
    MODULES+=("$module")
  done
  [ "${#MODULES[@]}" -gt 0 ]
}

# Fail unless $output contains the given text. Unlike a bare [[ ... ]], this
# fails the test even when it is not the last command: bash 3.2 (macOS
# /bin/bash) does not apply errexit to a failing [[ ... ]].
# $output is set by bats' run.
# shellcheck disable=SC2154
assert_output_contains() {
  case "$output" in
    *"$1"*) return 0 ;;
  esac
  printf 'expected output to contain: %s\n' "$1" >&2
  return 1
}

# Fail if $output contains the given text.
refute_output_contains() {
  case "$output" in
    *"$1"*)
      printf 'expected output not to contain: %s\n' "$1" >&2
      return 1
      ;;
  esac
  return 0
}

# Run herdr with a throwaway HOME and config path, so tests never read or
# write the real ~/.config/herdr and never reach a running herdr server.
# Usage: herdr_isolated <config-file> <herdr args...>
herdr_isolated() {
  local config="$1" home
  shift
  home="$(mktemp -d "$BATS_TEST_TMPDIR/herdr-home.XXXXXX")"
  mkdir -p "$home/.config/herdr" || return
  cp "$config" "$home/.config/herdr/config.toml" || return
  env -u HERDR_SOCKET_PATH -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_CONFIG_PATH -u HERDR_SESSION \
    HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_STATE_HOME="$home/.local/state" \
    XDG_DATA_HOME="$home/.local/share" \
    HERDR_CONFIG_PATH="$home/.config/herdr/config.toml" \
    herdr "$@"
}
