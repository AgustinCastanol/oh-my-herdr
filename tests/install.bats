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
  assert_output_contains "modules (git scratch sidebar)"
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
  diff <(config_body "$CONFIG_FILE") <(expected_body gentle scratch sidebar)
  [ ! -e "$BACKUP_FILE" ]
  [ "$(state_value modules)" = "scratch sidebar" ]
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
  diff <(config_body "$CONFIG_FILE") <(expected_body gentle git scratch sidebar)
  [ "$(state_value modules)" = "git scratch sidebar" ]
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
  [ "$(state_value modules)" = "engram git quiet scratch sidebar task-runner" ]
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
  diff <(config_body "$CONFIG_FILE") <(expected_body gentle engram git quiet scratch sidebar task-runner)
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

@test "a recorded module that was renamed is migrated, and a vanished one is dropped" {
  run_installer
  [ "$status" -eq 0 ]
  sed 's/^modules=.*/modules=scratch sidebar-summary retired/' "$STATE_FILE" >"$STATE_FILE.new"
  mv "$STATE_FILE.new" "$STATE_FILE"
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "module sidebar-summary is now called sidebar"
  assert_output_contains "module retired no longer exists; skipping it"
  [ "$(state_value modules)" = "scratch sidebar" ]
  diff <(config_body "$CONFIG_FILE") <(expected_body gentle scratch sidebar)
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
  diff <(config_body "$CONFIG_FILE") <(expected_body gentle scratch sidebar)
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
  diff <(config_body "$CONFIG_FILE") <(expected_body tokyo-night scratch sidebar)
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

@test "the engram module is a default when engram is on PATH" {
  use_stub engram
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  diff <(config_body "$CONFIG_FILE") <(expected_body gentle engram scratch sidebar)
  [ "$(state_value modules)" = "engram scratch sidebar" ]
}

@test "the task-runner module is a default when jq is on PATH" {
  fake_command jq
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  diff <(config_body "$CONFIG_FILE") <(expected_body gentle scratch sidebar task-runner)
  [ "$(state_value modules)" = "scratch sidebar task-runner" ]
}

# --- Integration hints ----------------------------------------------------

# Put an executable that does nothing on PATH under the given name.
fake_command() {
  printf '#!/bin/sh\nexit 0\n' >"$TEST_BIN/$1"
  chmod +x "$TEST_BIN/$1"
}

@test "install suggests integrations for agents on PATH and outdated ones" {
  fake_command claude
  fake_command cursor-agent
  INSTALL_ENV+=("STUB_HERDR_INTEGRATIONS=claude: not installed (/h/.claude/hooks/a.sh)
codex: outdated (v1 < v2) (/h/.codex/a.sh)
cursor: not installed (/h/.cursor/a.sh)
opencode: not installed (/h/.config/opencode/a.js)
pi: current (v3) (/h/.pi/a.ts)
letta (experimental): not installed (/h/.letta/a.sh)")
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "herdr integration install claude"
  assert_output_contains "herdr integration install codex"
  assert_output_contains "herdr integration install cursor"
  refute_output_contains "herdr integration install opencode"
  refute_output_contains "herdr integration install pi"
  refute_output_contains "herdr integration install letta"
  refute_logged "herdr integration install"
}

@test "install prints no integration hint when every integration is current" {
  fake_command claude
  INSTALL_ENV+=("STUB_HERDR_INTEGRATIONS=claude: current (v4) (/h/.claude/hooks/a.sh)")
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr integration status"
  refute_output_contains "herdr integration"
}

@test "install falls back to a generic integration hint when status fails" {
  # The failing status still prints a parseable line on stdout and on stderr;
  # neither may turn into a suggestion, and the install still succeeds.
  fake_command claude
  INSTALL_ENV+=("STUB_HERDR_INTEGRATION_FAIL=1"
    "STUB_HERDR_INTEGRATIONS=claude: not installed (/h/.claude/hooks/a.sh)")
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "oh-my-herdr is installed."
  assert_output_contains "Tip: run 'herdr integration status'"
  refute_output_contains "herdr integration install"
  refute_output_contains "stderr-noise"
}

@test "--dry-run does not query integrations" {
  run_installer --dry-run
  [ "$status" -eq 0 ]
  refute_logged "herdr integration"
}

# --- User overrides -------------------------------------------------------

# Write $2 to the user dir as $1, e.g. user_file keys.toml '[keys]...'.
user_file() {
  mkdir -p "$(dirname "$TEST_USER_DIR/$1")"
  printf '%s\n' "$2" >"$TEST_USER_DIR/$1"
}

@test "a keys.toml in the user dir replaces the shipped keys" {
  user_file keys.toml $'[keys]\nprefix = "ctrl+b"'
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  diff <(config_body "$CONFIG_FILE") <(expected_body gentle scratch sidebar)
  grep -qx 'prefix = "ctrl+b"' "$CONFIG_FILE"
  [ "$(grep -c 'prefix = "ctrl+a"' "$CONFIG_FILE")" = 0 ]
  assert_output_contains "$TEST_USER_DIR/keys.toml instead of the shipped keys.toml"
}

@test "a base.toml in the user dir replaces the shipped base" {
  user_file base.toml $'onboarding = false\n\n[ui]\nstatus_indicators = "dots"'
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  diff <(config_body "$CONFIG_FILE") <(expected_body gentle scratch sidebar)
  grep -qx 'status_indicators = "dots"' "$CONFIG_FILE"
}

@test "a theme in the user dir is selectable by name and shadows a shipped one" {
  user_file themes/mine.toml $'[theme]\nname = "nord"'
  user_file themes/gentle.toml $'[theme]\nname = "dracula"'
  run_installer --theme mine --modules none
  echo "$output"
  [ "$status" -eq 0 ]
  diff <(config_body "$CONFIG_FILE") <(expected_body mine)
  [ "$(state_value theme)" = "mine" ]

  run_installer --theme gentle
  [ "$status" -eq 0 ]
  diff <(config_body "$CONFIG_FILE") <(expected_body gentle)
  grep -qx 'name = "dracula"' "$CONFIG_FILE"
}

@test "a module in the user dir is selectable by name and shadows a shipped one" {
  user_file modules/mine.toml $'[[keys.command]]\nkey = "prefix+u"\ntype = "popup"\ncommand = "true"'
  user_file modules/scratch.toml $'[ui.sound]\nenabled = false'
  run_installer --modules scratch,mine
  echo "$output"
  [ "$status" -eq 0 ]
  diff <(config_body "$CONFIG_FILE") <(expected_body gentle scratch mine)
  [ "$(state_value modules)" = "scratch mine" ]
  assert_output_contains "$TEST_USER_DIR/modules/mine.toml"
  assert_output_contains "$TEST_USER_DIR/modules/scratch.toml instead of the shipped modules/scratch.toml"
}

@test "an override that herdr rejects aborts and leaves the config untouched" {
  write_user_config
  user_file keys.toml $'[keys]\nnot_a_herdr_key = 1'
  run_installer
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "herdr rejected the generated config"
  cmp "$CONFIG_FILE" "$BATS_TEST_TMPDIR/original.toml"
  [ ! -e "$BACKUP_FILE" ]
}

@test "--dry-run lists the layers that come from the user dir" {
  user_file keys.toml $'[keys]\nprefix = "ctrl+b"'
  user_file themes/mine.toml $'[theme]\nname = "nord"'
  local before
  before="$(snapshot_home)"
  run_installer --dry-run --theme mine
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "$TEST_USER_DIR/keys.toml instead of the shipped keys.toml"
  assert_output_contains "Using your $TEST_USER_DIR/themes/mine.toml"
  [ "$(snapshot_home)" = "$before" ]
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

@test "a pre-marker git install is adopted and updated" {
  INSTALL_ENV=("STUB_GIT_CLONE_SOURCE=$TEST_SOURCE")
  mkdir -p "${OMH_DATA_DIR%/*}" && cp -R "$TEST_SOURCE" "$OMH_DATA_DIR" && mkdir "$OMH_DATA_DIR/.git"
  write_legacy_state git
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "git -C $OMH_DATA_DIR pull --ff-only"
  grep -qx 'kind=git' "$OWNER_FILE"
}

@test "a pre-marker local install is adopted" {
  write_legacy_state "local:$TEST_SOURCE"
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qx 'kind=local' "$OWNER_FILE"
}

@test "a pre-marker local install next to foreign files is still refused" {
  write_legacy_state "local:$TEST_SOURCE"
  printf 'my notes\n' >"$OMH_DATA_DIR/notes.txt"
  local before
  before="$(snapshot_home)"
  run_installer
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "was not created by oh-my-herdr"
  [ "$(snapshot_home)" = "$before" ]
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

@test "a plugin whose required tool is on PATH is linked" {
  add_plugin_requiring demo oh-my-herdr.test-demo jq
  printf '#!/bin/sh\nexit 0\n' >"$TEST_BIN/jq"
  chmod +x "$TEST_BIN/jq"
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr plugin link $TEST_SOURCE/plugins/demo"
  [ "$(state_value plugins)" = "oh-my-herdr.test-demo" ]
}

@test "a plugin whose required tool is missing is skipped with a message" {
  add_plugin_requiring demo oh-my-herdr.test-demo jq
  add_plugin other oh-my-herdr.test-other
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "skipping plugin oh-my-herdr.test-demo: it needs jq, which is not on PATH"
  refute_logged "herdr plugin link $TEST_SOURCE/plugins/demo"
  assert_logged "herdr plugin link $TEST_SOURCE/plugins/other"
  [ "$(state_value plugins)" = "oh-my-herdr.test-other" ]
}

@test "a recorded plugin whose tool vanished stays recorded with a warning" {
  add_plugin_requiring demo oh-my-herdr.test-demo jq
  fake_command jq
  run_installer
  [ "$status" -eq 0 ]
  [ "$(state_value plugins)" = "oh-my-herdr.test-demo" ]
  rm "$TEST_BIN/jq"
  : >"$STUB_LOG"
  run_installer
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "plugin oh-my-herdr.test-demo stays linked from an earlier install, but it needs jq, which is not on PATH"
  refute_logged "herdr plugin link"
  [ "$(state_value plugins)" = "oh-my-herdr.test-demo" ]

  INSTALL_ENV+=("STUB_HERDR_SERVER=running")
  run_installer --uninstall --yes
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged "herdr plugin unlink oh-my-herdr.test-demo"
}

@test "--dry-run lists the plugins it would link and skip" {
  add_plugin_requiring demo oh-my-herdr.test-demo jq
  add_plugin other oh-my-herdr.test-other
  run_installer --dry-run
  echo "$output"
  [ "$status" -eq 0 ]
  assert_output_contains "herdr plugin link $TEST_SOURCE/plugins/other"
  assert_output_contains "skip plugin oh-my-herdr.test-demo: it needs jq"
  refute_logged "herdr plugin link"
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

# Run install.sh with the real herdr in place of the stub; skip the test when
# herdr is missing. The test HOME keeps it away from the user's herdr.
run_installer_with_real_herdr() {
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
    "$INSTALL_SHELL_PATH" "$INSTALL_SH" "$@"
}

@test "real herdr accepts the config install.sh writes with all modules" {
  run_installer_with_real_herdr --modules all
  echo "$output"
  [ "$status" -eq 0 ]
  run herdr_isolated "$CONFIG_FILE" config check
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "config: ok" ]
}

@test "real herdr rejects a broken user override and the config stays untouched" {
  write_user_config
  user_file keys.toml $'[keys]\nnot_a_herdr_key = 1'
  run_installer_with_real_herdr
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "unknown config key keys.not_a_herdr_key"
  cmp "$CONFIG_FILE" "$BATS_TEST_TMPDIR/original.toml"
}
