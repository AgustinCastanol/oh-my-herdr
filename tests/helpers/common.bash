# shellcheck shell=bash
# Shared helpers for oh-my-herdr bats tests. Load with: load helpers/common

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
MODULES_DIR="$CONFIG_DIR/modules"
HERDR_REFERENCE="$BATS_TEST_DIRNAME/fixtures/herdr-0.9.5-config-reference.json"
export REPO_ROOT CONFIG_DIR MODULES_DIR HERDR_REFERENCE

# Run the offline config checker. See tests/helpers/config_lint.py for subcommands.
config_lint() {
  python3 -I "$BATS_TEST_DIRNAME/helpers/config_lint.py" "$@"
}

# Print every module file, one per line, in a stable order. Fails when there
# are none, so a loop over modules can never pass without checking anything.
module_files() {
  local module status=1
  for module in "$MODULES_DIR"/*.toml; do
    [ -e "$module" ] || continue
    printf '%s\n' "$module"
    status=0
  done
  return "$status"
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
  env -u HERDR_SOCKET_PATH -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_CONFIG_PATH \
    HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_STATE_HOME="$home/.local/state" \
    XDG_DATA_HOME="$home/.local/share" \
    HERDR_CONFIG_PATH="$home/.config/herdr/config.toml" \
    herdr "$@"
}
