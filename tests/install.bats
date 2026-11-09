#!/usr/bin/env bats
# Tests for install.sh. herdr, brew, curl, git, and lazygit are stubs from
# tests/stubs; see tests/helpers/install.bash. Only the last test uses a real
# herdr, under an isolated HOME, and it is skipped when herdr is missing.
#
# Each test runs in its own subshell, so changing INSTALL_ENV in one test is
# meant to stay local to it.
# shellcheck disable=SC2030,SC2031

setup() {
  load helpers/common
  load helpers/install
  setup_install_env
}

write_user_config() {
  mkdir -p "${CONFIG_FILE%/*}"
  printf '# my own herdr config\n[theme]\nname = "nord"\n' >"$CONFIG_FILE"
  cp "$CONFIG_FILE" "$BATS_TEST_TMPDIR/original.toml"
}

# --- Usage ----------------------------------------------------------------

@test "--help prints usage and changes nothing" {
  run_installer --help
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "--modules"
  assert_output_contains "--uninstall"
  [ ! -s "$STUB_LOG" ]
}

@test "an unknown option is an error" {
  run_installer --bogus
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "unknown option: --bogus"
}

@test "an unsupported operating system is an error" {
  use_stub uname
  INSTALL_ENV+=("STUB_UNAME=FreeBSD")
  run_installer
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "Linux and macOS"
  [ ! -e "$CONFIG_FILE" ]
}

# --- Install --------------------------------------------------------------

@test "--dry-run prints the plan and changes nothing" {
  write_user_config
  remove_stub herdr
  use_stub brew
  local before
  before="$(snapshot_home)"
  run_installer --dry-run --modules all
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "dry run"
  assert_output_contains "brew install herdr"
  assert_output_contains "$BACKUP_FILE"
  [ "$(snapshot_home)" = "$before" ]
  refute_logged "brew install"
}

@test "a first-time dry run previews the modules a real run would pick" {
  INSTALL_ENV=("STUB_GIT_CLONE_SOURCE=$TEST_SOURCE")
  use_stub lazygit
  local before
  before="$(snapshot_home)"
  run_installer --dry-run
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "modules (git scratch)"
  assert_output_contains "theme (gentle)"
  [ "$(snapshot_home)" = "$before" ]
  [ -z "$(ls -A "$TEST_TMP")" ]
}

@test "install.sh sees only the stubs and the curated system utilities" {
  # $PATH must expand inside the test environment, not here.
  # shellcheck disable=SC2016
  run_in_install_env "$INSTALL_SHELL_PATH" -c 'printf "%s\n" "$PATH"'
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_BIN:$TEST_SYSBIN" ]
  run_in_install_env "$INSTALL_SHELL_PATH" -c 'command -v lazygit brew'
  [ "$status" -ne 0 ]
}

@test "fresh install writes base plus default modules and records state" {
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  head -n 1 "$CONFIG_FILE" | grep -q '^# Managed by oh-my-herdr'
  # lazygit is not on PATH, so the git module is not a default.
  diff <(config_body "$CONFIG_FILE") <(expected_body gentle scratch)
  [ ! -e "$BACKUP_FILE" ]
  [ "$(state_value modules)" = "scratch" ]
  [ "$(state_value config)" = "$CONFIG_FILE" ]
  [ -z "$(state_value backup)" ]
  # The config was checked by herdr at a temporary path, not in place.
  grep -q '^herdr config check HERDR_CONFIG_PATH=' "$STUB_LOG"
  refute_logged "herdr config check HERDR_CONFIG_PATH=$CONFIG_FILE"
  refute_logged "herdr plugin link"
  assert_output_contains "next time herdr starts"
}

@test "the git module is a default when lazygit is on PATH" {
  use_stub lazygit
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  diff <(config_body "$CONFIG_FILE") <(expected_body gentle git scratch)
  [ "$(state_value modules)" = "git scratch" ]
}

@test "an existing config is backed up once and kept across re-runs" {
  write_user_config
  run_installer
  [ "$status" -eq 0 ]
  cmp "$BACKUP_FILE" "$BATS_TEST_TMPDIR/original.toml"
  [ "$(state_value backup)" = "$BACKUP_FILE" ]
  local inode
  inode="$(ls -i "$BACKUP_FILE")"

  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  cmp "$BACKUP_FILE" "$BATS_TEST_TMPDIR/original.toml"
  [ "$(ls -i "$BACKUP_FILE")" = "$inode" ]
}

@test "re-running install produces an identical config" {
  run_installer --modules all
  [ "$status" -eq 0 ]
  cp "$CONFIG_FILE" "$BATS_TEST_TMPDIR/first.toml"
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  cmp "$CONFIG_FILE" "$BATS_TEST_TMPDIR/first.toml"
  # Without --modules, a re-run keeps the modules recorded at install time.
  [ "$(state_value modules)" = "git quiet scratch" ]
}

@test "an unmanaged config with an existing backup is refused" {
  write_user_config
  printf 'older backup\n' >"$BACKUP_FILE"
  local before
  before="$(snapshot_home)"
  run_installer
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "$BACKUP_FILE"
  [ "$(snapshot_home)" = "$before" ]
}

@test "local.toml is appended after the modules" {
  mkdir -p "${LOCAL_TOML%/*}"
  printf '[ui.toast.herdr]\nposition = "top-right"\n' >"$LOCAL_TOML"
  run_installer --modules quiet
  echo "$output"
  [ "$status" -eq 0 ]
  diff <(config_body "$CONFIG_FILE") <(expected_body gentle quiet -- "$LOCAL_TOML")
}

@test "a failing herdr config check aborts and leaves the config untouched" {
  write_user_config
  INSTALL_ENV+=("STUB_HERDR_CHECK_FAIL=1")
  run_installer
  echo "$output"
  [ "$status" -ne 0 ]
  assert_output_contains "stub: unknown config key ui.bogus"
  cmp "$CONFIG_FILE" "$BATS_TEST_TMPDIR/original.toml"
  [ ! -e "$BACKUP_FILE" ]
  [ "$(find "${CONFIG_FILE%/*}" -type f | wc -l | tr -d ' ')" = 1 ]
}

# --- Modules --------------------------------------------------------------

@test "--modules all selects every module" {
  run_installer --modules all
  [ "$status" -eq 0 ]
  diff <(config_body "$CONFIG_FILE") <(expected_body gentle git quiet scratch)
}

@test "--modules none writes the base config only" {
  run_installer --modules none
  [ "$status" -eq 0 ]
  diff <(config_body "$CONFIG_FILE") <(expected_body gentle)
  [ -z "$(state_value modules)" ]
}

@test "--modules takes a comma-separated list in the given order" {
  run_installer --modules=quiet,scratch,quiet
  echo "$output"
  [ "$status" -eq 0 ]
  diff <(config_body "$CONFIG_FILE") <(expected_body gentle quiet scratch)
}

@test "--modules with an unknown module is an error and changes nothing" {
  write_user_config
  local before
  before="$(snapshot_home)"
  run_installer --modules git,nope
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "unknown module: nope"
  [ "$(snapshot_home)" = "$before" ]
}

@test "selecting a module whose tool is missing warns" {
  run_installer --modules git
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "lazygit"
}

# --- Themes ---------------------------------------------------------------

@test "the default theme is gentle and is recorded" {
  [ "$(default_theme)" = gentle ]
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  diff <(config_body "$CONFIG_FILE") <(expected_body gentle scratch)
  [ "$(state_value theme)" = "gentle" ]
}

@test "--theme selects another theme" {
  run_installer --theme tokyo-night --modules none
  echo "$output"
  [ "$status" -eq 0 ]
  diff <(config_body "$CONFIG_FILE") <(expected_body tokyo-night)
  [ "$(state_value theme)" = "tokyo-night" ]
}

@test "--theme with an unknown theme is an error and changes nothing" {
  write_user_config
  local before
  before="$(snapshot_home)"
  run_installer --theme=nope
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "unknown theme: nope"
  assert_output_contains "gentle"
  [ "$(snapshot_home)" = "$before" ]
}

@test "a re-run without --theme keeps the recorded theme" {
  run_installer --theme tokyo-night
  [ "$status" -eq 0 ]
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  diff <(config_body "$CONFIG_FILE") <(expected_body tokyo-night scratch)
  [ "$(state_value theme)" = "tokyo-night" ]
}

@test "--dry-run shows the theme a real run would use" {
  run_installer --theme tokyo-night
  [ "$status" -eq 0 ]
  local before
  before="$(snapshot_home)"
  run_installer --dry-run
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "theme (tokyo-night)"
  [ "$(snapshot_home)" = "$before" ]
}

@test "--theme cannot be combined with --uninstall" {
  run_installer --uninstall --yes --theme gentle
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "--theme"
}

# --- herdr ----------------------------------------------------------------

@test "a missing herdr is installed with brew when brew is available" {
  remove_stub herdr
  use_stub brew
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "brew install herdr"
  refute_logged "curl"
  [ -f "$CONFIG_FILE" ]
}

@test "a missing herdr is installed with the herdr install script without brew" {
  remove_stub herdr
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  # Downloaded to a file and checked before it runs; never piped into sh.
  assert_logged_prefix "curl -fsSL https://herdr.dev/install.sh -o $TEST_TMP/"
  assert_output_contains "$TEST_HOME/.local/bin is not on your PATH"
  [ -f "$CONFIG_FILE" ]
  [ -z "$(ls -A "$TEST_TMP")" ]
}

@test "a failed herdr download stops before anything changes" {
  remove_stub herdr
  write_user_config
  INSTALL_ENV+=("STUB_CURL_FAIL=1")
  local before
  before="$(snapshot_home)"
  run_installer
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "could not download https://herdr.dev/install.sh"
  [ "$(snapshot_home)" = "$before" ]
  [ -z "$(ls -A "$TEST_TMP")" ]
}

@test "an empty herdr download stops before anything changes" {
  remove_stub herdr
  write_user_config
  INSTALL_ENV+=("STUB_CURL_EMPTY=1")
  local before
  before="$(snapshot_home)"
  run_installer
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "is empty"
  [ "$(snapshot_home)" = "$before" ]
}

@test "a herdr older than 0.9.0 is an error and changes nothing" {
  write_user_config
  INSTALL_ENV+=("STUB_HERDR_VERSION=0.8.9")
  local before
  before="$(snapshot_home)"
  run_installer
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "herdr update"
  assert_output_contains "brew upgrade herdr"
  [ "$(snapshot_home)" = "$before" ]
}

@test "a running herdr server reloads the config" {
  INSTALL_ENV+=("STUB_HERDR_SERVER=running")
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr server reload-config"
}

# --- Source ---------------------------------------------------------------

@test "without OMH_SOURCE the repo is cloned, then pulled on the next run" {
  INSTALL_ENV=("STUB_GIT_CLONE_SOURCE=$TEST_SOURCE")
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  # Cloned into a temporary directory first, then moved into place.
  assert_logged_prefix "git clone --depth 1 https://github.com/AgustinCastanol/oh-my-herdr.git $TEST_TMP/"
  [ -f "$OMH_DATA_DIR/config/base.toml" ]
  [ -d "$OMH_DATA_DIR/.git" ]
  [ -f "$OWNER_FILE" ]
  [ -z "$(ls -A "$TEST_TMP")" ]

  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "git -C $OMH_DATA_DIR pull --ff-only"
}

@test "OMH_SOURCE equal to the install directory is refused" {
  INSTALL_ENV=("OMH_SOURCE=$TEST_SOURCE" "OMH_DIR=$TEST_SOURCE")
  run_installer
  echo "$output"
  [ "$status" -eq 1 ]
  [ ! -e "$CONFIG_FILE" ]
}

@test "an OMH_DIR inside the source checkout is refused" {
  INSTALL_ENV=("OMH_SOURCE=$TEST_SOURCE" "OMH_DIR=$TEST_SOURCE/state")
  run_installer
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "source checkout"
  [ ! -e "$TEST_SOURCE/state" ]
  [ ! -e "$CONFIG_FILE" ]
}

@test "an OMH_DIR that contains the source checkout is refused" {
  INSTALL_ENV=("OMH_SOURCE=$TEST_SOURCE" "OMH_DIR=$BATS_TEST_TMPDIR")
  run_installer
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "source checkout"
  [ ! -e "$CONFIG_FILE" ]
}

@test "a non-empty OMH_DIR that oh-my-herdr did not create is refused (local source)" {
  mkdir -p "$OMH_DATA_DIR"
  printf 'my notes\n' >"$OMH_DATA_DIR/notes.txt"
  local before
  before="$(snapshot_home)"
  run_installer
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "was not created by oh-my-herdr"
  [ "$(snapshot_home)" = "$before" ]
}

@test "a non-empty OMH_DIR that oh-my-herdr did not create is refused (git source)" {
  INSTALL_ENV=("STUB_GIT_CLONE_SOURCE=$TEST_SOURCE")
  mkdir -p "$OMH_DATA_DIR"
  printf 'my notes\n' >"$OMH_DATA_DIR/notes.txt"
  local before
  before="$(snapshot_home)"
  run_installer
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "was not created by oh-my-herdr"
  [ "$(snapshot_home)" = "$before" ]
  refute_logged "git clone"
}

# --- Plugins --------------------------------------------------------------

@test "plugins in the source are linked on install and unlinked on uninstall" {
  add_plugin demo oh-my-herdr.test-demo
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr plugin link $TEST_SOURCE/plugins/demo"
  [ "$(state_value plugins)" = "oh-my-herdr.test-demo" ]

  INSTALL_ENV+=("STUB_HERDR_SERVER=running")
  run_installer --uninstall --yes
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr plugin unlink oh-my-herdr.test-demo"
}

@test "uninstall without a running server explains how to unlink plugins later" {
  add_plugin demo oh-my-herdr.test-demo
  run_installer
  [ "$status" -eq 0 ]
  run_installer --uninstall --yes
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "herdr plugin unlink oh-my-herdr.test-demo"
}

@test "a plugin recorded earlier stays recorded when linking it fails" {
  add_plugin demo oh-my-herdr.test-demo
  run_installer
  [ "$status" -eq 0 ]
  INSTALL_ENV+=("STUB_HERDR_LINK_FAIL=1")
  run_installer
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "could not link plugin oh-my-herdr.test-demo"
  [ "$(state_value plugins)" = "oh-my-herdr.test-demo" ]
}

@test "a plugin removed upstream is unlinked when herdr is running" {
  add_plugin demo oh-my-herdr.test-demo
  add_plugin other oh-my-herdr.test-other
  run_installer
  [ "$status" -eq 0 ]
  rm -rf "$TEST_SOURCE/plugins/other"
  INSTALL_ENV+=("STUB_HERDR_SERVER=running")
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr plugin unlink oh-my-herdr.test-other"
  [ "$(state_value plugins)" = "oh-my-herdr.test-demo" ]
}

@test "a plugin removed upstream stays recorded when herdr is not running" {
  add_plugin demo oh-my-herdr.test-demo
  add_plugin other oh-my-herdr.test-other
  run_installer
  [ "$status" -eq 0 ]
  rm -rf "$TEST_SOURCE/plugins/other"
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "oh-my-herdr.test-other"
  refute_logged "herdr plugin unlink"
  [ "$(state_value plugins)" = "oh-my-herdr.test-demo oh-my-herdr.test-other" ]

  # Uninstall still tries every recorded plugin, even after one fails.
  INSTALL_ENV+=("STUB_HERDR_SERVER=running" "STUB_HERDR_UNLINK_FAIL=oh-my-herdr.test-demo")
  run_installer --uninstall --yes
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr plugin unlink oh-my-herdr.test-demo"
  assert_logged "herdr plugin unlink oh-my-herdr.test-other"
}

# --- Uninstall ------------------------------------------------------------

@test "uninstall restores the original config byte for byte" {
  write_user_config
  run_installer --modules all
  [ "$status" -eq 0 ]
  run_installer --uninstall --yes
  echo "$output"
  [ "$status" -eq 0 ]
  cmp "$CONFIG_FILE" "$BATS_TEST_TMPDIR/original.toml"
  [ ! -e "$BACKUP_FILE" ]
  [ ! -e "$OMH_DATA_DIR" ]
  assert_output_contains "herdr itself was not removed"
}

@test "uninstall with no prior config removes only the managed file" {
  run_installer
  [ "$status" -eq 0 ]
  printf 'keep me\n' >"${CONFIG_FILE%/*}/notes.txt"
  mkdir -p "${LOCAL_TOML%/*}"
  printf '[ui.sound]\nenabled = true\n' >"$LOCAL_TOML"
  run_installer --uninstall --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$CONFIG_FILE" ]
  [ -f "${CONFIG_FILE%/*}/notes.txt" ]
  [ -f "$LOCAL_TOML" ]
  [ ! -e "$OMH_DATA_DIR" ]
}

@test "uninstall keeps files in OMH_DIR that oh-my-herdr did not create" {
  run_installer
  [ "$status" -eq 0 ]
  printf 'my notes\n' >"$OMH_DATA_DIR/notes.txt"
  run_installer --uninstall --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(cat "$OMH_DATA_DIR/notes.txt")" = "my notes" ]
  [ ! -e "$STATE_FILE" ]
  [ ! -e "$OWNER_FILE" ]
}

@test "uninstall deletes an OMH_DIR that install cloned" {
  INSTALL_ENV=("STUB_GIT_CLONE_SOURCE=$TEST_SOURCE")
  run_installer
  [ "$status" -eq 0 ]
  run_installer --uninstall --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$OMH_DATA_DIR" ]
}

@test "uninstall never deletes recursively without the ownership marker" {
  INSTALL_ENV=("STUB_GIT_CLONE_SOURCE=$TEST_SOURCE")
  run_installer
  [ "$status" -eq 0 ]
  rm "$OWNER_FILE"
  run_installer --uninstall --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$OMH_DATA_DIR/config/base.toml" ]
}

@test "uninstall leaves a config that oh-my-herdr does not manage" {
  run_installer
  [ "$status" -eq 0 ]
  write_user_config
  run_installer --uninstall --yes
  echo "$output"
  [ "$status" -eq 0 ]
  cmp "$CONFIG_FILE" "$BATS_TEST_TMPDIR/original.toml"
}

@test "uninstall without --yes refuses when stdin is not a terminal" {
  run_installer
  [ "$status" -eq 0 ]
  local before
  before="$(snapshot_home)"
  run_installer --uninstall </dev/null
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "--yes"
  [ "$(snapshot_home)" = "$before" ]
}

@test "uninstall --dry-run changes nothing" {
  write_user_config
  run_installer
  [ "$status" -eq 0 ]
  local before
  before="$(snapshot_home)"
  run_installer --uninstall --dry-run
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "$BACKUP_FILE"
  [ "$(snapshot_home)" = "$before" ]
}

# --- Real herdr -----------------------------------------------------------

@test "real herdr accepts the config install.sh writes with all modules" {
  local real_herdr
  real_herdr="$(command -v herdr)" || skip "herdr is not on PATH"
  remove_stub herdr
  run env -i \
    PATH="$TEST_BIN:${real_herdr%/*}:$TEST_SYSBIN" \
    HOME="$TEST_HOME" \
    TMPDIR="$TEST_TMP" \
    TERM=dumb \
    STUB_LOG="$STUB_LOG" \
    OMH_SOURCE="$TEST_SOURCE" \
    "$INSTALL_SHELL_PATH" "$INSTALL_SH" --modules all
  echo "$output"
  [ "$status" -eq 0 ]
  run herdr_isolated "$CONFIG_FILE" config check
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "config: ok" ]
}
